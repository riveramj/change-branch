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
#
# Commands:
#   hubot switch|change|build {job} to|with {branch} - Change {job} to {branch} on Jenkins and build.
#   hubot (show) current branch for {job} - Shows current branch for {job} on Jenkins.
#   hubot (go) build yourself|(go) ship yourself - Rebuilds default branch if set.
#   hubot list jobs|jenkins list|jobs {job} - Shows all jobs in Jenkins. Filters by job if provided.
#   hubot build|rebuild {job} - Rebuilds {job}.
#   hubot enable|disable {job} - Enable or disable {job} on jenkins.
# 
# Author: 
#   hacklanta

{parseString} = require 'xml2js'

jenkinsURL = process.env.HUBOT_JENKINS_URL
jenkinsUser = process.env.HUBOT_JENKINS_USER
jenkinsUserAPIKey = process.env.HUBOT_JENKINS_USER_API_KEY
jenkinsHubotJob = process.env.HUBOT_JENKINS_JOB_NAME || ''

get = (robot, queryOptions, callback) ->
  robot.http("#{jenkinsURL}/#{queryOptions}")
    .auth("#{jenkinsUser}", "#{jenkinsUserAPIKey}")
    .get() (err, res, body) ->
      callback(err, res, body)

post = (robot, queryOptions, postOptions, callback) ->
  robot.http("#{jenkinsURL}/#{queryOptions}")
    .auth("#{jenkinsUser}", "#{jenkinsUserAPIKey}")
    .post(postOptions) (err, res, body) ->
      callback(err, res, body)

buildBranch = (robot, msg, job, branch = "") ->
  post robot, "job/#{job}/build", "", (err, res, body) ->
    if err
      msg.send "Encountered an error on build :( #{err}"
    else if res.statusCode is 201
      if branch 
        msg.send "#{job} is building with #{branch}"
      else if job == jenkinsHubotJob
        msg.send "I'll Be right back"
      else
        msg.send "#{job} is building."
        
    else
      msg.send "something went wrong with #{res.statusCode} :(" 

getCurrentBranch = (body) ->
  branch = ""
  parseString body, (err, result) ->
    branch = result?.project?.scm[0]?.branches[0]['hudson.plugins.git.BranchSpec'][0].name[0]

  branch

buildJob = (robot, msg) ->
  job = msg.match[2]

  get robot, "job/#{job}/", (err, res, body) ->
    if res.statusCode is 404
      msg.send "No can do. Didn't find job '#{job}'."
    else if res.statusCode == 200
      buildBranch(robot, msg, job)

switchBranch = (robot, msg) ->
  job = msg.match[2]
  branch = msg.match[4]

  get robot, "job/#{job}/config.xml", (err, res, body) ->
    if err
      msg.send "Encountered an error :( #{err}"
    else
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
        else if  res.statusCode is 404
          msg.send "job '#{job}' not found" 
        else
          msg.send "something went wrong :(" 
 
showCurrentBranch = (robot, msg) ->
  job = msg.match[2]
 
  get robot, "job/#{job}/config.xml", (err, res, body) ->
    if err
      msg.send "Encountered an error :( #{err}"
    else  
      currentBranch = getCurrentBranch(body)
      if currentBranch? 
         msg.send("current branch is '#{currentBranch}'")
      else
         msg.send("Did not find job '#{job}'")

listJobs = (robot, msg) ->
  jobFilter = new RegExp(msg.match[2],"i")
  
  get robot, "api/json", (err, res, body) ->
    if err
      msg.send "Encountered an error :( #{err}"
    else
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
  changeState = msg.match[1]
  job = msg.match[2]

  post robot, "job/#{job}/#{changeState}", "", (err, res, body) ->
    if err
      msg.send "something went wrong! Error: #{err}."
    else if res.statusCode == 302
      msg.send "#{job} has been set to #{changeState}."
    else if res.statusCode == 404
      msg.send "Job '#{job}' does not exist."
    else
      msg.send "Not sure what happened. You should check #{jenkinsURL}/job/#{job}/"

module.exports = (robot) ->             
  robot.respond /(switch|change|build) (.+) (to|with) (.+)/i, (msg) ->
    switchBranch(robot, msg)

  robot.respond /(show\s)?current branch for (.+)/i, (msg) ->
    showCurrentBranch(robot, msg)
  
  robot.respond /(go )?(build yourself)|(go )?(ship yourself)/i, (msg) ->
    if jenkinsHubotJob
      buildBranch(robot, msg, jenkinsHubotJob)
    else
      msg.send("No hubot job found. Set {HUBOT_JENKINS_JOB_NAME} to job name.")

  robot.respond /(list jobs|jenkins list|jobs)\s*(.*)/i, (msg) ->
    listJobs(robot, msg)

  robot.respond /(build|rebuild) (.+)/i, (msg) ->
    buildJob(robot, msg)

  robot.respond /(disable|enable) (.+)/i, (msg) ->
    changeJobState(robot, msg)
      



