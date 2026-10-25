import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const controller = readFileSync(new URL("../TiPorto/WebViewController.swift", import.meta.url), "utf8")
const script = controller.match(/let js = """\r?\n([\s\S]*?)\r?\n\s*"""/)[1]
const probe = controller.match(/let probe = """\r?\n([\s\S]*?)\r?\n\s*"""/)[1]

function bridge (pathname = "/login", offline = false)
{
	const messages = []
	const listeners = new Map()
	const location = {pathname, href: `https://app.tiporto.io${pathname}`}
	const document = {
		documentElement: {classList: {contains: name => name === "tp-offline" && offline}},
		addEventListener: (name, callback) => listeners.set(name, callback),
	}
	const window = {
		webkit: {messageHandlers: {inertiaNav: {postMessage: message => messages.push(message)}}},
		addEventListener: (name, callback) => listeners.set(name, callback),
	}
	const history = {pushState () {}, replaceState () {}}
	vm.runInNewContext(script, {window, document, history, location, navigator: {onLine: true}})
	return {messages, listeners, window, history, location}
}

test("a successful SPA login requests one native GET reload instead of retaining offline state", () =>
{
	const app = bridge("/verifySMS", true)
	app.location.pathname = "/Home"
	app.location.href = "https://app.tiporto.io/Home"
	app.history.pushState({}, "", "/Home")
	app.listeners.get("inertia:navigate")()
	app.listeners.get("inertia:finish")()
	const completed = app.messages.filter(message => message.action === "authCompleted")
	assert.equal(completed.length, 1)
	assert.equal(completed[0].href, "https://app.tiporto.io/Home")
	assert.equal(completed[0].offline, true)
})

test("the offline banner retry invokes native retry and stops the stale SPA handler", () =>
{
	const app = bridge("/Home", true)
	let prevented = false
	let stopped = false
	const event = {
		target: {closest: selector => selector === '[role="status"] button' ? {} : null},
		preventDefault: () => {prevented = true},
		stopImmediatePropagation: () => {stopped = true},
	}
	assert.equal(typeof app.listeners.get("click"), "function")
	app.listeners.get("click")(event)
	assert.equal(app.messages.at(-1).action, "retryOffline")
	assert.equal(prevented, true)
	assert.equal(stopped, true)
})

test("ordinary online clicks and offline navigation do not fake a successful connection", () =>
{
	const app = bridge("/Home")
	const before = app.messages.length
	const event = {target: {closest: () => ({})}, preventDefault: () => assert.fail(), stopImmediatePropagation: () => assert.fail()}
	assert.equal(typeof app.listeners.get("click"), "function")
	app.listeners.get("click")(event)
	assert.equal(app.messages.length, before)
	assert.equal(app.window.__TiPortoNativeNetworkOnline, undefined)
	const cachedApp = bridge("/Transports/Today", true)
	cachedApp.location.pathname = "/Transports/Past"
	cachedApp.location.href = "https://app.tiporto.io/Transports/Past"
	cachedApp.history.pushState({}, "", "/Transports/Past")
	assert.equal(cachedApp.messages.at(-1).offline, true)
	assert.equal(cachedApp.messages.some(message => message.action === "authCompleted"), false)
})

test("failed authentication and public pages never trigger an authenticated reload", () =>
{
	for (const pathname of ["/login", "/login/database", "/verifySMS", "/Privacy"])
	{
		const app = bridge("/verifySMS")
		app.location.pathname = pathname
		app.location.href = `https://app.tiporto.io${pathname}`
		app.history.replaceState({}, "", pathname)
		assert.equal(app.messages.some(message => message.action === "authCompleted"), false)
	}
})

test("offline save and navigation buttons are not captured as retry", () =>
{
	const app = bridge("/Home", true)
	const before = app.messages.length
	app.listeners.get("click")({target: {closest: () => null}, preventDefault: () => assert.fail(), stopImmediatePropagation: () => assert.fail()})
	assert.equal(app.messages.length, before)
})

async function probeConnection (fetch)
{
	return vm.runInNewContext(`(async () => {${probe}})()`, {
		fetch, url: "https://app.tiporto.io/Home", location: {origin: "https://app.tiporto.io"},
		URL, AbortController, setTimeout, clearTimeout,
	})
}

test("automatic reconnect probes the server with HEAD, bypassing caches and performing no CRUD", async () =>
{
	const calls = []
	assert.equal(await probeConnection(async (url, options) =>
	{
		calls.push({url, options})
		return {status: 200, url}
	}), true)
	assert.equal(calls.length, 1)
	assert.equal(calls[0].options.method, "HEAD")
	assert.equal(calls[0].options.cache, "no-store")
	assert.equal(calls[0].options.credentials, "same-origin")
	assert.equal(calls[0].options.mode, "same-origin")
	assert.equal(calls[0].options.body, undefined)
})

test("a missing connection or host error never falsely marks the server reachable", async () =>
{
	assert.equal(await probeConnection(async () => {throw new Error("disconnected")}), false)
	for (const status of [500, 503, 521, 522])
	{
		assert.equal(await probeConnection(async url => ({status, url})), false)
	}
})

test("a revoked session is left for the real page request, not replaced with cached authentication", async () =>
{
	for (const status of [401, 403, 419])
	{
		assert.equal(await probeConnection(async url => ({status, url})), true)
	}
	assert.equal(await probeConnection(async () => ({status: 200, url: "https://app.tiporto.io/login"})), true)
	assert.equal(await probeConnection(async () => ({status: 200, url: "https://other.example/Home"})), false)
})
