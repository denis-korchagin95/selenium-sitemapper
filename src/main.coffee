request       = require 'request'
webDriver     = require 'selenium-webdriver'
chrome        = require 'selenium-webdriver/chrome'
async         = require 'async'
urlParse      = require 'url-parse'
normalizeUrl  = require 'normalize-url'
EventEmitter  = require 'events'
fs            = require 'fs'
path          = require 'path'


# https://coffeescript-cookbook.github.io/chapters/arrays/removing-duplicate-elements-from-arrays
Array::unique = ->
	output = {}
	output[@[key]] = @[key] for key in [0...@length]
	value for key, value of output


class Store extends EventEmitter
	constructor: (@entryUrl) ->
		do super
		@_parsedEntryUrl = urlParse @entryUrl
		@urlStack = [ @entryUrl ]
		@currentUrl = null
		@urlVisitedMap = {}
		@probeUrlCache = {}
		@totalProceedUrls = 0

		@urlVisitedMap[@entryUrl] = on

	getEntryUrl: -> @entryUrl

	hasUrlProbeResult: (url) -> @probeUrlCache[url]?

	readUrlProbeResult: (url) -> @probeUrlCache[url]

	writeUrlProbeResult: (url, result) -> @probeUrlCache[url] = result

	getCurrentUrl: -> @currentUrl

	getCurrentHost: -> @_parsedEntryUrl.host

	isNotVisitedUrl: (url) -> not @urlVisitedMap[url]

	isNotInQueueUrl: (url) -> @urlStack.indexOf(url) is -1

	remainedUrlCount: -> @urlStack.length

	getScannedUrls: -> Object.keys @urlVisitedMap

	totalProceedUrlCount: -> @totalProceedUrls

	addInQueue: (url) ->
		@urlStack.push url
		@emit 'queue:on-add', url

	isRemainedUrlsToScan: -> @urlStack.length > 0

	next: ->
		++@totalProceedUrls
		@currentUrl = do @urlStack.pop
		@urlVisitedMap[@currentUrl] = on
		@currentUrl


dimensions =
	width: 1920
	height: 1080

driver = null

isDrownOutErrors = no

isHeadlessMode = no

dropHashes = yes
dropQuery = no
subLevelMatch = 2
removeTrailingSlash = no
stripWWW = no
outputFile = './sitemap.json'


prepareProbeFunction = (store, url) ->
	(cb) ->
		process.stdout.write "Probing `#{url}`...\n"
		if store.hasUrlProbeResult url
			isAccept = store.readUrlProbeResult url
			process.stdout.write "Probing status for `#{url}`: #{if isAccept then 'OK!' else 'FAIL!'}\n"
			return cb null, {isAccept: isAccept, url: url}
		probeUrl url, (err, isAccept, res) ->
			return cb err if err
			process.stdout.write "Probing status for `#{url}`: #{if isAccept then 'OK!' else 'FAIL!'}\n"
			store.writeUrlProbeResult url, isAccept
			cb null, {isAccept: isAccept, url: url}


probeUrl = (url, cb) ->
	request url, method: 'head', (err, res) ->
		return cb err if err
		isSuccess = res.statusCode < 300 and res.statusCode >= 200
		isHtml = (res.headers['content-type'] or '').indexOf('text/html') isnt -1
		cb null, isSuccess and isHtml, res


isSameHost = (host, url, subLevelMatch = 2) ->
	return on if subLevelMatch <= 0
	parsedUrl = urlParse url
	hostSubDomens = (host or '').split '.'
	parsedUrlHostSubDomens = (parsedUrl.host or '').split '.'
	hostSubDomens.slice(-subLevelMatch).join('.') is parsedUrlHostSubDomens.slice(-subLevelMatch).join '.'


fetchLinksFromUrl = (driver, url, cb) ->
	driver.get url
		.then -> driver.findElements webDriver.By.tagName 'a'
		.then (links) ->
			promiseList = []
			for link in links
				promiseList.push link.getAttribute 'href'
			Promise.all promiseList
		.then (links) -> cb null, links
		.catch (err) -> cb err


doNormalizeUrl = (url) ->
	options =
		removeTrailingSlash: removeTrailingSlash
		stripWWW: stripWWW

	urlObject = urlParse url
	dropHashIfItEmpty = if do urlObject.hash.trim is '#' then on else no

	options.stripHash = dropHashIfItEmpty

	normalizeUrl url, options

if not process.env.ENTRY_URL?
	console.log 'error: require entry url'
	do process.exit


store = new Store doNormalizeUrl process.env.ENTRY_URL


process.on 'SIGINT', ->
	isDrownOutErrors = yes
	if driver?
		driver.close()
			.catch (err) -> console.error err

process.on 'unhandledRejection', (reason, promise) ->
	console.error 'Unhandled Rejection: ', reason


async.waterfall [
	(cb) ->
		chromeOptions = new chrome.Options()

		if isHeadlessMode
			do chromeOptions.headless

		chromeOptions.windowSize dimensions

		driver = new webDriver.Builder()
			.forBrowser 'chrome'
			.setChromeOptions chromeOptions
			.build()

		cb null
	(cb) ->
		entryUrl = do store.getEntryUrl
		process.stdout.write "Probing `#{entryUrl}`...\n"
		probeUrl entryUrl, (err, isAccept, res) ->
			return cb err if err
			process.stdout.write "Probing status for `#{entryUrl}`: #{if isAccept then 'OK!' else 'FAIL!'}\n"
			if not isAccept
				cb new Error "bad entrypoint: #{entryUrl}"
			else
				cb null
	(cb) ->

		async.whilst(
			(cb) -> cb null, do store.isRemainedUrlsToScan
			(cb) ->
				currentUrl = do store.next


				console.log "\n\n"
				console.log "Urls to scan: #{do store.remainedUrlCount} (+1) [current]"
				console.log "Total urls: #{do store.totalProceedUrlCount - 1} (+1) [current]"
				console.log "\n\n"


				async.waterfall [
					(cb) ->
						console.log "Fetching links from `#{currentUrl}`..."
						fetchLinksFromUrl driver, currentUrl, cb
					(links, cb) ->
						filteredLinks = (doNormalizeUrl link for link in links when isSameHost do store.getCurrentHost, link, subLevelMatch)
						filteredLinks = do filteredLinks.unique

						url2ProbeList = (prepareProbeFunction store, link for link in filteredLinks)

						async.parallelLimit url2ProbeList, 16, (err, results) ->
							return cb err if err
							cb null, (result.url for result in results when result.isAccept)

					(probedUrls, cb) ->
						for url in probedUrls
							if store.isNotVisitedUrl(url) and store.isNotInQueueUrl url
								store.addInQueue url
								console.log "\t\tadded url to scan: `#{url}`"
						cb null

				], (err) ->
					return cb err if err
					cb null

			(err) ->
				return cb err if err
				cb null
		)

], (err) ->
	driver.close()
		.then ->
			return Promise.reject err if err

			console.log 'DONE!'

			urls = do store.getScannedUrls

			filename = path.join __dirname, outputFile

			fs.writeFileSync filename, JSON.stringify(urls, null, 1), enconding: 'utf-8'

			console.log "Total scanned urls: #{urls.length}"
			console.log "The sitemap writes to `#{filename}`"

		.catch (err) ->
			if isDrownOutErrors
				return
			console.error err
			console.log 'Trying to save data...'
