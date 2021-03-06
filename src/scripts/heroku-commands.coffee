# Description:
#   Exposes Heroku commands to hubot
#
# Dependencies:
#   "heroku-client": "^1.9.0"
#   "hubot-auth": "^1.2.0"
#
# Configuration:
#   HUBOT_HEROKU_API_KEY
#
# Commands:
#   hubot heroku list apps <app name filter> - Lists all apps or filtered by the name
#   hubot heroku info <app> - Returns useful information about the app
#   hubot heroku dynos <app> - Lists all dynos and their status
#   hubot heroku releases <app> - Latest 10 releases
#   hubot heroku rollback <app> <version> - Rollback to a release
#   hubot heroku restart <app> <dyno> - Restarts the specified app or dyno/s (e.g. worker or web.2)
#   hubot heroku migrate <app> - Runs migrations. Remember to restart the app =)
#   hubot heroku config <app> - Get config keys for the app. Values not given for security
#   hubot heroku config:set <app> <KEY=value> - Set KEY to value. Case sensitive and overrides present key
#   hubot heroku config:unset <app> <KEY> - Unsets KEY, does not throw error if key is not present
#   hubot heroku run rake <app> <task> - Runs a specific rake task
#
# Author:
#   daemonsy

Heroku          = require('heroku-client')
objectToMessage = require("../object-to-message")

heroku = new Heroku(token: process.env.HUBOT_HEROKU_API_KEY)
_      = require('lodash')
moment = require('moment')
useAuth = (process.env.HUBOT_HEROKU_USE_AUTH or '').trim().toLowerCase() is 'true'

module.exports = (robot) ->
  auth = (msg, appName) ->
    if appName
      role = "heroku-#{appName}"
      hasRole = robot.auth.hasRole(msg.envelope.user, role)

    isAdmin = robot.auth.hasRole(msg.envelope.user, 'admin')

    if useAuth and not (hasRole or isAdmin)
      msg.reply "Access denied. You must have this role to use this command: #{role}"
      return false
    return true

  respondToUser = (robotMessage, error, successMessage) ->
    if error
      robotMessage.reply "Shucks. An error occurred. #{error.statusCode} - #{error.body.message}"
    else
      robotMessage.reply successMessage

  # App List
  robot.respond /(heroku list apps)\s?(.*)/i, (msg) ->
    return unless auth(msg)

    searchName = msg.match[2] if msg.match[2].length > 0

    if searchName
      msg.reply "Listing apps matching: #{searchName}"
    else
      msg.reply "Listing all apps available..."

    heroku.apps().list (error, list) ->
      list = list.filter (item) -> item.name.match(new RegExp(searchName, "i"))

      result = if list.length > 0 then list.map((app) -> objectToMessage(app, "appShortInfo")).join("\n\n") else "No apps found"

      respondToUser(msg, error, result)

  # App Info
  robot.respond /heroku info (.*)/i, (msg) ->
    return unless auth(msg, appName)

    appName = msg.match[1]

    msg.reply "Getting information about #{appName}"

    heroku.apps(appName).info (error, info) ->
      successMessage = "\n" + objectToMessage(info, "info") unless error
      respondToUser(msg, error, successMessage)

  # Dynos
  robot.respond /heroku dynos (.*)/i, (msg) ->
    appName = msg.match[1]

    return unless auth(msg, appName)

    msg.reply "Getting dynos of #{appName}"

    heroku.apps(appName).dynos().list (error, dynos) ->
      output = []
      if dynos
        output.push "Dynos of #{appName}"
        lastFormation = ""

        for dyno in dynos
          currentFormation = "#{dyno.type}.#{dyno.size}"

          unless currentFormation is lastFormation
            output.push "" if lastFormation
            output.push "=== #{dyno.type} (#{dyno.size}): `#{dyno.command}`"
            lastFormation = currentFormation

          updatedAt = moment(dyno.updated_at)
          updatedTime = updatedAt.utc().format('YYYY/MM/DD HH:mm:ss')
          timeAgo = updatedAt.fromNow()
          output.push "#{dyno.name}: #{dyno.state} #{updatedTime} (~ #{timeAgo})"

      respondToUser(msg, error, output.join("\n"))

  # Releases
  robot.respond /heroku releases (.*)$/i, (msg) ->
    appName = msg.match[1]

    return unless auth(msg, appName)

    msg.reply "Getting releases for #{appName}"

    heroku.apps(appName).releases().list (error, releases) ->
      output = []
      if releases
        output.push "Recent releases of #{appName}"

        for release in releases.sort((a, b) -> b.version - a.version)[0..9]
          output.push "v#{release.version} - #{release.description} - #{release.user.email} -  #{release.created_at}"

      respondToUser(msg, error, output.join("\n"))

  # Rollback
  robot.respond /heroku rollback (.*) (.*)$/i, (msg) ->
    appName = msg.match[1]
    version = msg.match[2]

    return unless auth(msg, appName)

    if version.match(/v\d+$/)
      msg.reply "Telling Heroku to rollback to #{version}"

      app = heroku.apps(appName)
      app.releases().list (error, releases) ->
        release = _.find releases, (release) ->
          "v#{release.version}" ==  version

        return msg.reply "Version #{version} not found for #{appName} :(" unless release

        app.releases().rollback release: release.id, (error, release) ->
          respondToUser(msg, error, "Success! v#{release.version} -> Rollback to #{version}")

  # Restart
  robot.respond /heroku restart ([\w-]+)\s?(\w+(?:\.\d+)?)?/i, (msg) ->
    appName = msg.match[1]
    dynoName = msg.match[2]
    dynoNameText = if dynoName then ' '+dynoName else ''

    return unless auth(msg, appName)

    msg.reply "Telling Heroku to restart #{appName}#{dynoNameText}"

    unless dynoName
      heroku.apps(appName).dynos().restartAll (error, app) ->
        respondToUser(msg, error, "Heroku: Restarting #{appName}")
    else
      heroku.apps(appName).dynos(dynoName).restart (error, app) ->
        respondToUser(msg, error, "Heroku: Restarting #{appName}#{dynoNameText}")

  # Migration
  robot.respond /heroku migrate (.*)/i, (msg) ->
    appName = msg.match[1]

    return unless auth(msg, appName)

    msg.reply "Telling Heroku to migrate #{appName}"

    heroku.apps(appName).dynos().create
      command: "rake db:migrate"
      attach: false
    , (error, dyno) ->
      respondToUser(msg, error, "Heroku: Running migrations for #{appName}")

      heroku.apps(appName).logSessions().create
        dyno: dyno.name
        tail: true
      , (error, session) ->
        respondToUser(msg, error, "View logs at: #{session.logplex_url}")

  # Config Vars
  robot.respond /heroku config (.*)$/i, (msg) ->
    appName = msg.match[1]

    return unless auth(msg, appName)

    msg.reply "Getting config keys for #{appName}"

    heroku.apps(appName).configVars().info (error, configVars) ->
      listOfKeys = configVars && Object.keys(configVars).join(", ")
      respondToUser(msg, error, listOfKeys)

  robot.respond /heroku config:set (.*) (\w+)=('([\s\S]+)'|"([\s\S]+)"|([\s\S]+\b))/im, (msg) ->
    keyPair = {}

    appName = msg.match[1]
    key     = msg.match[2]
    value   = msg.match[4] || msg.match[5] || msg.match[6] # :sad_panda:

    return unless auth(msg, appName)

    msg.reply "Setting config #{key} => #{value}"

    keyPair[key] = value

    heroku.apps(appName).configVars().update keyPair, (error, configVars) ->
      respondToUser(msg, error, "Heroku: #{key} is set to #{configVars[key]}")

  robot.respond /heroku config:unset (.*) (\w+)$/i, (msg) ->
    keyPair = {}
    appName = msg.match[1]
    key     = msg.match[2]
    value   = msg.match[3]

    return unless auth(msg, appName)

    msg.reply "Unsetting config #{key}"

    keyPair[key] = null

    heroku.apps(appName).configVars().update keyPair, (error, response) ->
      respondToUser(msg, error, "Heroku: #{key} has been unset")

  # Run Rake
  robot.respond /heroku run rake (.+) (.+)$/i, (msg) ->
    appName = msg.match[1]
    task = msg.match[2]

    return unless auth(msg, appName)

    msg.reply "Telling Heroku to run `rake #{task}` on #{appName}"

    heroku.apps(appName).dynos().create
      command: "rake #{task}"
      attach: false
    , (error, dyno) ->
      respondToUser(msg, error, "Heroku: Running `rake #{task}` for #{appName}")

      heroku.apps(appName).logSessions().create
        dyno: dyno.name
        tail: true
      , (error, session) ->
        respondToUser(msg, error, "View logs at: #{session.logplex_url}")
