// Settings page for every StreamSmith action. The Stream Deck app loads this
// and calls connectElgatoStreamDeckSocket; the plugin sends the scene and
// source lists through sendToPropertyInspector.
//
// Settings store ids, never names, so renaming a scene or source in
// StreamSmith doesn't break a button.

let websocket = null;
let uuid = null;
let actionUUID = "";
let settings = {};
let data = { online: false, port: 4460, scenes: [], sources: [] };

const el = (id) => document.getElementById(id);

const ROWS = {
	"com.streamsmith.remote.scene": ["row-scene"],
	"com.streamsmith.remote.streaming": [],
	"com.streamsmith.remote.recording": [],
	"com.streamsmith.remote.mute": ["row-source"],
	"com.streamsmith.remote.volume": ["row-source", "row-step", "row-direction"],
	"com.streamsmith.remote.visibility": ["row-scene", "row-source"],
};

function connectElgatoStreamDeckSocket(port, inUUID, registerEvent, _info, actionInfo) {
	uuid = inUUID;
	const info = typeof actionInfo === "string" ? JSON.parse(actionInfo) : actionInfo || {};
	actionUUID = info.action || "";
	settings = (info.payload && info.payload.settings) || {};

	websocket = new WebSocket("ws://127.0.0.1:" + port);
	websocket.onopen = () => {
		websocket.send(JSON.stringify({ event: registerEvent, uuid: inUUID }));
		sendToPlugin({ action: "getData" });
	};
	websocket.onmessage = (event) => {
		const msg = JSON.parse(event.data);
		if (msg.event === "sendToPropertyInspector" && msg.payload && msg.payload.event === "streamsmith") {
			data = msg.payload;
			render();
		} else if (msg.event === "didReceiveSettings") {
			settings = (msg.payload && msg.payload.settings) || {};
			render();
		}
	};

	showRows();
	render();
}
window.connectElgatoStreamDeckSocket = connectElgatoStreamDeckSocket;

function sendToPlugin(payload) {
	if (!websocket || websocket.readyState !== 1) return;
	websocket.send(JSON.stringify({ event: "sendToPlugin", action: actionUUID, context: uuid, payload }));
}

function saveSettings() {
	if (!websocket || websocket.readyState !== 1) return;
	websocket.send(JSON.stringify({ event: "setSettings", context: uuid, payload: settings }));
}

function showRows() {
	const wanted = ROWS[actionUUID] || [];
	for (const id of ["row-scene", "row-source", "row-step", "row-direction"]) {
		el(id).classList.toggle("hidden", !wanted.includes(id));
	}
}

// Fills a <select>, keeping the saved id selected even when it is gone from
// the list -- a button set up for another show shouldn't silently retarget.
function fillSelect(select, items, selectedId, missingLabel) {
	select.innerHTML = "";
	let found = false;
	for (const item of items) {
		const option = document.createElement("option");
		option.value = item.id;
		option.textContent = item.name;
		if (item.id === selectedId) {
			option.selected = true;
			found = true;
		}
		select.appendChild(option);
	}
	if (selectedId && !found) {
		const option = document.createElement("option");
		option.value = selectedId;
		option.textContent = missingLabel;
		option.selected = true;
		select.appendChild(option);
	}
	if (!selectedId && items.length > 0) {
		select.selectedIndex = 0;
	}
}

function sourcesForAction() {
	// Mute and volume only make sense for sources that carry audio;
	// visibility only for sources placed in the chosen scene.
	if (actionUUID === "com.streamsmith.remote.mute" || actionUUID === "com.streamsmith.remote.volume") {
		return data.sources.filter((s) => s.audio);
	}
	if (actionUUID === "com.streamsmith.remote.visibility") {
		const scene = data.scenes.find((s) => s.id === settings.sceneId);
		if (!scene) return [];
		return scene.sources
			.map((id) => data.sources.find((s) => s.id === id))
			.filter(Boolean);
	}
	return data.sources;
}

function render() {
	const offline = !data.online;

	fillSelect(el("scene"), data.scenes, settings.sceneId, "(missing scene)");
	fillSelect(el("source"), sourcesForAction(), settings.sourceId, "(missing source)");
	el("step").value = Math.round((settings.step || 0.05) * 100);
	el("direction").value = settings.direction || "up";
	el("port").value = data.port;

	for (const id of ["scene", "source", "step", "direction"]) {
		el(id).disabled = offline;
	}

	const note = el("note");
	note.classList.toggle("offline", offline);
	note.textContent = offline
		? "StreamSmith is not running, or remote control is off in its settings."
		: "Connected to StreamSmith on port " + data.port + ".";
}

el("scene").addEventListener("change", (e) => {
	settings.sceneId = e.target.value;
	// The source list depends on the scene for the visibility action.
	settings.sourceId = "";
	saveSettings();
	render();
});

el("source").addEventListener("change", (e) => {
	settings.sourceId = e.target.value;
	saveSettings();
});

el("step").addEventListener("change", (e) => {
	const percent = Math.min(50, Math.max(1, parseInt(e.target.value, 10) || 5));
	e.target.value = percent;
	settings.step = percent / 100;
	saveSettings();
});

el("direction").addEventListener("change", (e) => {
	settings.direction = e.target.value;
	saveSettings();
});

// The port is shared by every button, so it lives in the plugin's global
// settings rather than this button's settings.
el("port").addEventListener("change", (e) => {
	const port = Math.min(65535, Math.max(1, parseInt(e.target.value, 10) || 4460));
	e.target.value = port;
	sendToPlugin({ action: "setPort", port });
});
