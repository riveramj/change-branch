# Description:
#   Changes the branch on your jenkins instance remotely
#
# Dependencies:
#   Nope
#
# Configuration:
#   HUBOT_JENKINS_URL - Jenkins base URL
#   HUBOT_JENKINS_USER - Jenins admin user
#   HUBOT_JENKINS_USER_API_KEY - Admin user API key. Not your password. Find at "{HUBOT_JENKINS_URL}/{HUBOT_JENKINS_USER}/configure" 
#   HUBOT_JENKINS_JOB_NAME - Hubot job name on Jenkins (optional)
#   GITHUB_TOKEN - Github API Auth token (optional)
#
# Commands:
#   hubot switch|change|build {job} to|with {branch} - Change job to branch on Jenkins and build.
#   hubot (show|current|show current) branch for {job} - Shows current branch for job on Jenkins.
#   hubot (go) build yourself|(go) ship yourself - Rebuilds default branch if set.
#   hubot list jobs|jenkins list|all jobs|jobs {job} - Shows all jobs in Jenkins. Filters by job if provided.
#   hubot build|rebuild {job} - Rebuilds job.
#   hubot enable|disable {job} - Enable or disable job on jenkins.
#   hubot show|show last|last (build|failure|output) for {job} - show output for last job
#   hubot show|show output|output for {job} {number} - show output job output for number given
#   hubot set branch message to {message} - set custom message when switching branches on a job
#   hubot remove branch message - remove custom message. Uses default message.
#   hubot show|show last|last (build|failure|output) for {job} - show output for last job.
#   hubot show|show output|output for {job} {number} - show output job output for number given.
#   hubot {job} status - show current build status and percent compelete of job and its dependencies.
#   hubot set job repos - Pulls list of jobs and repos from jenkins and places in memory to validate branch names if github token provided.
#   hubot remove job repos - Will remove job repos from memory.
#   hubot watch job {job-url} - Will check job every minute and notify you on completion
# 
# Author: 
#   hacklanta

{parseString} = require 'xml2js'
cronJob = require('cron').CronJob

jenkinsURL = process.env.HUBOT_JENKINS_URL
jenkinsUser = process.env.HUBOT_JENKINS_USER
jenkinsUserAPIKey = process.env.HUBOT_JENKINS_USER_API_KEY
jenkinsHubotJob = process.env.HUBOT_JENKINS_JOB_NAME || ''
githubToken = process.env.GITHUB_TOKEN || ''

JOBS = {}

getByFullUrl =  (robot, url, callback) ->
  robot.http(url)
    .auth("#{jenkinsUser}", "#{jenkinsUserAPIKey}")
    .get() (err, res, body) ->
      if err
        robot.send "Encountered an error :( #{err}"
      else
        callback(res, body)

get = (robot, msg, queryOptions, callback) ->
  robot.http("#{jenkinsURL}/#{queryOptions}")
    .auth("#{jenkinsUser}", "#{jenkinsUserAPIKey}")
    .get() (err, res, body) ->
      if err
        msg.send "Encountered an error :( #{err}"
      else
        callback(res, body)

post = (robot, queryOptions, postOptions, callback) ->
  robot.http("#{jenkinsURL}/#{queryOptions}")
    .auth("#{jenkinsUser}", "#{jenkinsUserAPIKey}")
    .post(postOptions) (err, res, body) ->
      callback(err, res, body)

ifJobEnabled = (robot, msg, job, callback) ->
  get robot, msg, "job/#{job}/config.xml", (res, body) ->
    if res.statusCode is 404
      msg.send "Job '#{job}' does not exist."
    else
      parseString body, (err, result) ->
        jobStatus = (result?.project?.disabled[0] == 'true')
        
        if jobStatus
          msg.send "No can do. '#{job}' is disabled."
        else
          callback()

doesJobExist = (robot, msg, job, callback) ->
  yardmaster = robot.brain.get 'yardmaster' || {}
  if yardmaster?.jobRepos?
    possibleJob = yardmaster.jobRepos.filter (potentialJob) -> potentialJob.job == job
    if possibleJob.length
       callback(true)
    else
      msg.send "Job '#{job}' does not exist. If the job does exist, you need to update your job repos. Run 'set job repos' and then try again."
  else
    get robot, msg, "job/#{job}/config.xml", (res, body) ->
      if res.statusCode is 404
        msg.send "Job '#{job}' does not exist."
      else
        callback(true)

buildBranch = (robot, msg, job, branch = "") ->
  ifJobEnabled robot, msg, job, (jobStatus) ->
    post robot, "job/#{job}/build", "", (err, res, body) ->
      queueUrl = res.headers?["location"]

      if err
        msg.send "Encountered an error on build :( #{err}"
      else if res.statusCode is 201
        if branch
          customMessage = robot.brain.get("yardmaster")?["build-message"]
          if customMessage
            customMessage = customMessage.replace /job/, job
            customMessage = customMessage.replace /branch/, branch
            msg.send customMessage
            watchQueue robot, queueUrl, msg
          else
            msg.send "#{job} is building with #{branch}. I'll keep an eye on it for you."
            watchQueue robot, queueUrl, msg
        else if job == jenkinsHubotJob
          msg.send "I'll Be right back"
        else
          msg.send "#{job} is building. I'll let you know when it's done."
          watchQueue robot, queueUrl, msg
      else
        msg.send "something went wrong with #{res.statusCode} :(" 

getCurrentBranch = (body) ->
  branch = ""
  parseString body, (err, result) ->
    branch = result?.project?.scm[0]?.branches[0]['hudson.plugins.git.BranchSpec'][0].name[0]

  branch

buildJob = (robot, msg) ->
  job = msg.match[2].trim()

  get robot, msg, "job/#{job}/", (res, body) ->
    if res.statusCode is 404
      msg.send "No can do. Didn't find job '#{job}'."
    else if res.statusCode == 200
      buildBranch(robot, msg, job)

switchBranch = (robot, msg) ->
  job = msg.match[2].trim()
  branch = msg.match[4].trim()

  ifJobEnabled robot, msg, job, (jobStatus) ->
    checkBranchName robot, msg, job, branch, (branchValid) ->
      get robot, msg, "job/#{job}/config.xml", (res, body) ->
        # this is a regex replace for the branch name
        # Spaces below are to keep the xml formatted nicely
        # TODO: parse as XML and replace string (drop regex)
        config = body.replace /\<hudson.plugins.git.BranchSpec\>\n\s*\<name\>.*\<\/name\>\n\s*<\/hudson.plugins.git.BranchSpec\>/g, "<hudson.plugins.git.BranchSpec>\n        <name>#{branch}</name>\n      </hudson.plugins.git.BranchSpec>" 
  
        # try to update config
        post robot, "job/#{job}/config.xml", config, (err, res, body) ->
          if err
            msg.send "Encountered an error :( #{err}"
          else if res.statusCode is 200
            # if update successful build branch
            buildBranch(robot, msg, job, branch)  
          else if res.statusCode is 404
            msg.send "Job '#{job}' not found" 
          else
            msg.send "something went wrong :(" 

findCurrentBranch = (robot, msg, job, callback) ->
  get robot, msg, "job/#{job}/config.xml", (res, body) ->
    currentBranch = getCurrentBranch(body)
    if currentBranch? 
       callback(currentBranch)
    else
       msg.send "Did not find current branch for #{job}."

listJobs = (robot, msg) ->
  jobFilter = new RegExp(msg.match[2].trim(),"i")
  
  get robot, msg, "api/json", (res, body) ->
    response = ""
    jobs = JSON.parse(body).jobs
    for job in jobs
      lastBuildState = if job.color == "blue" then "PASSING" else "FAILING"

      if jobFilter?
        if jobFilter.test job.name
          response += "#{job.name} is #{lastBuildState}: #{job.url}\n"
      else
        response += "#{job.name} is #{lastBuildState}: #{job.url}\n"
      
    msg.send """
      Here are the jobs
      #{response}
    """

changeJobState = (robot, msg) ->
  changeState = msg.match[1].trim()
  job = msg.match[2].trim()

  post robot, "job/#{job}/#{changeState}", "", (err, res, body) ->
    if err
      msg.send "something went wrong! Error: #{err}."
    else if res.statusCode == 302
      msg.send "#{job} has been set to #{changeState}."
    else if res.statusCode == 404
      msg.send "Job '#{job}' does not exist."
    else
      msg.send "Not sure what happened. You should check #{jenkinsURL}/job/#{job}/"

getJobTimeStamp = (robot, msg, jobUrl, callback) ->
  get robot, msg, "#{jobUrl}/api/json", (res, body) ->
    rawDateTime = JSON.parse(body).id
    timeAndDate = rawDateTime.split('_')
    timeAndDate[1] = timeAndDate[1].replace(/-/g, ":")
    callback(timeAndDate)

showBuildOuput = (robot, msg) ->
  lastJob = if msg.match[2].trim() == "failure" then "lastFailedBuild" else "lastBuild"
  job = msg.match[3].trim()

  get robot, msg, "job/#{job}/#{lastJob}/logText/progressiveText", (res, body) ->
    if res.statusCode is 404
      msg.send "Did not find job '#{job}."
    else
      getJobTimeStamp robot, msg, "job/#{job}/#{lastJob}", (timeAndDate) ->
        msg.send """
          Job last built on #{timeAndDate[0]} at #{timeAndDate[1]} utc 
          #{jenkinsURL}/job/#{job}/#{lastJob}/console
          Output is:
          #{body}
        """

showSpecificBuildOutput = (robot, msg) ->
  job = msg.match[2].trim()
  jobNumber = msg.match[3].trim()
  
  get robot, msg, "job/#{job}/#{jobNumber}/logText/progressiveText", (res, body) ->
    if res.statusCode is 404
      msg.send "Did not find output for job number '#{jobNumber}' for '#{job}."
    else
      getJobTimeStamp robot, msg, "job/#{job}/#{lastJob}", (timeStamp) ->
      msg.send """
        #{jenkinsURL}/job/#{job}/#{jobNumber}/console
        Output is: 
        #{body}
      """
isJobBuilding = (robot, msg, job, callback) ->
  get robot, msg, "job/#{job}/lastBuild/api/xml?depth=1", (res, body) ->
    parseString body, (err, result) ->
      isBuilding = result?.freeStyleBuild?.building[0] == "true"
      percentComplete = result?.freeStyleBuild?.executor?[0].progress[0] || 0
      callback(isBuilding, percentComplete)

getDownstreamJobs = (robot, msg, job, callback) ->
  get robot, msg, "job/#{job}/api/json", (res, body) ->
    jobs = JSON.parse(body).downstreamProjects
    downstreamJobs = []
    for job in jobs
      downstreamJobs.push job.name
    callback(downstreamJobs)

trackJobs = (robot, msg, jobs, jobStatus, callback) ->
  job = jobs.shift()
  isJobBuilding robot, msg, job, (isBuilding, percentComplete) ->
    if isBuilding
      jobStatus.push { name: job, percent: percentComplete }
      callback(jobStatus)
    else
      getDownstreamJobs robot, msg, job, (downstreamJobs) ->
        if downstreamJobs.length
          jobs = jobs.concat(downstreamJobs)
          trackJobs robot, msg, jobs, jobStatus, (callback)
        else if jobs.length
           trackJobs robot, msg, jobs, jobStatus, (callback)
        else 
          jobStatus.push { name: job }
          callback(jobStatus)

        jobStatus.push { name: job }

setJobRepos = (robot, msg) ->
  get robot, msg, "api/xml?tree=jobs[name,scm[*[*]]]", (res, body) ->
    parseString body, (err, result) ->
      jobs = result?.hudson?.job
      jobRepos = []
      for job in jobs
        jobName = job.name?[0]
        repoURL = job.scm?[0].userRemoteConfig?[0].url?[0]
        jobRepos.push "job": jobName, "repo": repoURL
      yardmaster = robot.brain.get('yardmaster') || {}
      yardmaster.jobRepos ||= {}
      yardmaster.jobRepos = jobRepos
      robot.brain.set 'yardmaster', yardmaster
      msg.send "Job repos set"

removeJobRepos = (robot, msg) ->
  yardmaster = robot.brain.get('yardmaster') || {}
  if yardmaster.jobRepos?
    delete yardmaster.jobRepos
    robot.brain.set 'yardmaster', yardmaster
    msg.send "Job repos deleted"
  else 
    msg.send "No job repos set. Nothing to delete."

getOwnerAndRepoForRepoURL = (repoURL) ->
  owner = ///
    .*\:(.*)/
    ///.exec repoURL

  repo = ///
    .*/(.*)\..*
    ///.exec repoURL
  
  [owner, repo]

checkBranchName = (robot, msg, job, branch, callback) ->
  yardmaster = robot.brain.get 'yardmaster' || {}
  currentJob = yardmaster?.jobRepos?.filter (potentialJob) -> potentialJob.job == job
  
  doesJobExist robot, msg, job, (exists) -> 
    if githubToken.length && currentJob?[0].repo?
      [owner, repo] = getOwnerAndRepoForRepoURL currentJob[0].repo
      
      robot.http("https://api.github.com/repos/#{owner[1]}/#{repo[1]}/branches/#{branch}")
        .header('Authorization', "token #{githubToken}")
        .get() (err, res, body) ->
          if err
            msg.send "Encountered an error :( #{err}"
          else
            if JSON.parse(body).name
              callback()
            else
              msg.send "Branch name '#{branch}' is not valid for repo '#{repo[1]}'."
    else 
      callback()
          
deployBranchToJob = (robot, msg) ->
  deployBranch = msg.match[2].trim()
  deployName = msg.match[3].trim()
  yardmaster = robot.brain.get('yardmaster') || {}
  
  deployJob = yardmaster?.buildJob?.filter (potentialJob) -> potentialJob.name == deployName
  knownJob = yardmaster?.jobRepos?.filter (potentialJob) -> potentialJob.job == deployJob?[0].job
  repoURL = knownJob?[0].repo
  
  if deployJob.length && repoURL?
    [owner, repo] = getOwnerAndRepoForRepoURL repoURL
    
    findCurrentBranch robot, msg, deployJob[0].job, (branch) ->
      body = {
        "base": branch,
        "head": deployBranch,
        "commit_message": "#{deployBranch} merged into #{branch} by #{robot.name}!"
      }
      postBody = JSON.stringify(body)

      robot.http("https://api.github.com/repos/#{owner[1]}/#{repo[1]}/merges")
        .header('Authorization', "token #{githubToken}")
        .post(postBody) (err, res, body) ->
          if res.statusCode == 201
            msg.send "Congrats! #{deployBranch} was merged into #{deployName} successfully."
          else
            msg.send """
              Something went wrong :(
              Status code is: #{res.statusCode}
              Check https://developer.github.com/v3/repos/merging/ to see what #{res.statusCode} means.
              """
  else
    msg.send "Did not find '#{deployJob}' in list of known deployment targets."
      

setBuildJob = (robot, msg) ->
  yardmaster = robot.brain.get('yardmaster') || {}
  yardmaster.deploymentJob ||= []
  buildName = msg.match[1].trim()
  buildJob = msg.match[2].trim()
  
  doesJobExist robot, msg, buildJob, (exists) ->
    existingJobs = yardmaster.deploymentJob?.filter (potentialJob) -> potentialJob.name != buildName
    if existingJobs?
      yardmaster.deploymentJob = existingJobs  
    yardmaster.deploymentJob.push { name: buildName, job: buildJob }
    robot.brain.set 'yardmaster', yardmaster
    msg.send "#{buildName} set to #{buildJob}."

registerNewWatchedJob = (robot, id, user, url, queue, msg) ->
  job = new WatchJob(id, user)
  if queue
    job.startQueue robot, url, msg
  else
    job.start robot, url, msg
  JOBS[id] = job

unregisterWatchedJob = (robot, id)->
  if JOBS[id]
    JOBS[id].stop()
    yardmaster = robot.brain.get('yardmaster') || {}
    yardmaster.watchJobs ||= {}
    delete yardmaster.watchJobs[id]
    delete JOBS[id]
    robot.brain.set 'yardmaster', yardmaster

createCronWatchJob = (robot, url, msg, queue = false) -> 
  id = Math.floor(Math.random() * 1000000) while !id? || JOBS[id]

  user = msg.message.user

  yardmaster = robot.brain.get('yardmaster') || {}
  yardmaster.watchJobs ||= {}
  yardmaster.watchJobs[id] = { jobUrl: url, user: user }
  robot.brain.set 'yardmaster', yardmaster
  
  registerNewWatchedJob robot, id, user, url, queue, msg
  
  if !queue
    msg.send "job #{url} added with id #{id}."

trimUrl = (url) ->
  urlCorrect = /[0-9]/.test(url.slice (url.length - 1))
  if urlCorrect
    url
  else 
    trimUrl url.slice(0, -1)

findJobNumber = (url, originalURL) ->
  possibleNumber = /[0-9]/.test(url.slice(url.length - 1))
  if !possibleNumber
    originalURL.slice(url.length, originalURL.length)
  else 
    findJobNumber url.slice(0, -1), originalURL


watchQueue = (robot, url, msg) ->
  trimmedURL = url.slice(0, url.length - 1)

  jobNumber = findJobNumber trimmedURL, trimmedURL

  queueUrl = "#{jenkinsURL}/queue/item/#{jobNumber}/api/json"

  getByFullUrl robot, queueUrl, (res, body) ->
    if res.statusCode is 404
      msg.send "#{url} does not seem to be a valid url. Couldn't watch job."
    else
      createCronWatchJob robot, queueUrl, msg, true

watchJob = (robot, msg) ->
  jobUrl = trimUrl msg.match[1].trim()

  getByFullUrl robot, "#{jobUrl}/api/json", (res, body) ->
    if res.statusCode is 404
      msg.send "#{jobUrl} does not seem to be a valid job url."
    else
      createCronWatchJob robot, jobUrl, msg
      
module.exports = (robot) ->
  robot.respond /(switch|change|build) (.+) (to|with) (.+)\.?/i, (msg) ->
    switchBranch(robot, msg)

  robot.respond /(show\s|current\s|show current\s)?branch for (.+)\.?/i, (msg) ->
    job = msg.match[2].trim()
    doesJobExist robot, msg, job, (exists) ->
      findCurrentBranch robot, msg, job, (branch) ->
        msg.send "Current branch for #{job} is #{branch}."
  
  robot.respond /(go )?(build yourself)|(go )?(ship yourself)\.?/i, (msg) ->
    if jenkinsHubotJob
      buildBranch(robot, msg, jenkinsHubotJob)
    else
      msg.send("No hubot job found. Set {HUBOT_JENKINS_JOB_NAME} to job name.")

  robot.respond /(list jobs|jenkins list|all jobs|jobs)\s*(.*)\.?/i, (msg) ->
    listJobs(robot, msg)

  robot.respond /(build|rebuild) (.+)/i, (msg) ->
    buildJob(robot, msg)

  robot.respond /(disable|enable) (.+)/i, (msg) ->
    changeJobState(robot, msg)
  
  robot.respond /(show|show last|last) (build|failure|output) for (.+)\.?/i, (msg) ->
    showBuildOuput(robot, msg)
  
  robot.respond /(show|show output|output) for (.+) ([0-9]+)\.?/i, (msg) ->
    showSpecificBuildOutput(robot, msg)

  robot.respond /(?:show|show last|last) (?:build\s)?(?:date|time) for (.+)\.?/i, (msg) ->
    job = msg.match[1].trim()
    getJobTimeStamp robot, msg, "job/#{job}/lastBuild", (timeAndDate) ->
        msg.send "#{job} last built on #{timeAndDate[0]} at #{timeAndDate[1]} utc"
  
  robot.respond /set branch message to (.+)\.?/i, (msg) ->
    message = msg.match[1].trim()
    yardmaster = robot.brain.get('yardmaster') || {}
    yardmaster.buildMessage ||= {}
    yardmaster.buildMessage = message
    robot.brain.set 'yardmaster', yardmaster
    msg.send "Custom branch message set."

  robot.respond /remove branch message\.?/i, (msg) ->
    yardmaster = robot.brain.get('yardmaster')
    if yardmaster?.buildMessage?
      delete yardmaster.buildMessage
      robot.brain.set 'yardmaster', yardmaster
      msg.send "Custom branch message removed."
    else
      msg.send "No custom branch message set. Nothing to delete."
      
  robot.respond /(.+) status\.?/i, (msg) ->
    job = msg.match[1].trim()
    doesJobExist robot, msg, job, (exists) ->
      if exists
        msg.send "Checking on #{job} and its dependencies for you."

        trackJobs robot, msg, [job], [], (callback) ->
          jobStatus = ""
          callback.map (jobEntry) -> 
            if jobEntry.percent
              jobStatus = jobStatus + "#{jobEntry.name} is building and is #{jobEntry.percent}% complete.\n"
            else
              jobStatus = jobStatus + "#{jobEntry.name} is not building.\n"
          msg.send jobStatus

  robot.respond /set job repos\.?/i, (msg) ->
    removeJobRepos robot, msg
    setJobRepos robot, msg
  
  robot.respond /remove job repos\.?/i, (msg) ->
    removeJobRepos robot, msg
  
  robot.respond /set (.+) job to (.+)\.?/i, (msg) ->
    setBuildJob robot, msg

  robot.respond /remove (.+) from deployments\.?/i, (msg) ->
    yardmaster = robot.brain.get('yardmaster')
    existingDemployments = yardmaster?.deploymentJob?.filter (existingJob) -> existingJob.name != msg.match[1].trim()
    robot.brain.set 'yardmaster', yardmaster
    msg.send "Removed #{msg.match[1].trim()} from deployment jobs."
     
  robot.respond /(deploy|merge|ship) (.+) to (.+)\.?/i, (msg) ->
    deployBranchToJob robot, msg

  robot.respond /watch job (.+)\.?/i, (msg) -> 
    watchJob robot, msg

class WatchJob
  constructor: (id, user) ->
    @id = id
    @user = user

  checkJobStatus: (url, robot, job, msg) ->
    getByFullUrl robot, "#{url}/api/json", (res, body) ->
      if res.statusCode is 404
        unregisterWatchedJob robot, job.id
        msg.send "#{url} does not seem to be a valid job url. Removing from watch list"
      else
        result = JSON.parse(body).result

        if result?
          unregisterWatchedJob robot, job.id
          msg.send "@#{job.user.name}, job #{url} finished with status: #{result}."

  checkQueueStatus: (url, robot, job, msg) ->
    getByFullUrl robot, url, (res, body) ->
      if res.statusCode is 404
        unregisterWatchedJob robot, job.id
        msg.send "#{url} does not seem to be a valid job url. Removing from watch list"
      else
        jobUrl = JSON.parse(body).executable?.url

        if jobUrl?
          unregisterWatchedJob robot, job.id
          createCronWatchJob robot, jobUrl, msg

  start: (robot, url, msg) ->
    @cronjob = new cronJob("*/1 * * * *", =>
      @checkJobStatus url, robot, this, msg
    )
    @cronjob.start()

  startQueue: (robot, url, msg) ->
    @cronjob = new cronJob("*/1 * * * *", =>
      @checkQueueStatus url, robot, this, msg
    )
    @cronjob.start()


  stop: ->
    @cronjob.stop()

  sendMessage: (robot, message) ->
    envelope = user: @user, room: @user.room
    robot.send envelope, message
