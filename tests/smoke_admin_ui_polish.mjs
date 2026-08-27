#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const apt = fs.readFileSync(new URL('../avian/frontend/apt.js', import.meta.url), 'utf8');
const html = fs.readFileSync(new URL('../avian/frontend/index.html', import.meta.url), 'utf8');
const css = fs.readFileSync(new URL('../avian/frontend/styles.css', import.meta.url), 'utf8');

function functionSource(name) {
  const start = apt.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} is present`);
  const body = apt.indexOf('{', start);
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = body; index < apt.length; index += 1) {
    const char = apt[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'" || char === '`') {
      quote = char;
      continue;
    }
    if (char === '{') depth += 1;
    if (char === '}' && --depth === 0) return apt.slice(start, index + 1);
  }
  throw new Error(`${name} has no closing brace`);
}

const markupContext = {};
vm.createContext(markupContext);
vm.runInContext([
  functionSource('settingsInfoMarkup'),
  functionSource('lanAuthRow'),
  functionSource('passwordChangeRow'),
  functionSource('birdweatherRow'),
].join('\n'), markupContext);

const accessOff = markupContext.lanAuthRow({
  lan_admin_auth: false,
  password_configured: true,
});
assert.match(accessOff, /role="tooltip"/, 'Access details use a tooltip');
assert.match(accessOff, /aria-describedby="lanAuthTip"/, 'the switch exposes tooltip copy to assistive technology');
assert.doesNotMatch(accessOff, /lan-auth-warning/, 'Access no longer reserves a warning paragraph');
assert.equal(markupContext.passwordChangeRow({
  lan_admin_auth: false,
  password_configured: true,
}), '', 'password change stays hidden while local password protection is off');
assert.match(markupContext.passwordChangeRow({
  lan_admin_auth: true,
  password_configured: true,
}), /data-password-change-open/, 'password change appears while local password protection is on');

const birdweatherOff = markupContext.birdweatherRow({
  ok: true,
  enabled: false,
  token_configured: false,
  upload_audio: false,
  privacy_threshold: 0,
});
assert.match(birdweatherOff, /type="password" data-birdweather-token/, 'BirdWeather token is a password input');
assert.doesNotMatch(birdweatherOff, /data-birdweather-token[^>]*\svalue=/, 'BirdWeather never puts a saved token in the DOM');
assert.match(birdweatherOff, /data-v="1" aria-current="true"/, 'a fresh station starts at local privacy level one');
assert.match(birdweatherOff, /does not redact the full recording/, 'privacy disclosure distinguishes filtering from audio redaction');
const birdweatherUnavailable = markupContext.birdweatherRow({ ok: false });
assert.match(birdweatherUnavailable, /data-birdweather-disclosure[^>]* disabled/, 'unavailable BirdWeather Details action is disabled');
assert.match(birdweatherUnavailable, /class="birdweather-unavailable"[^>]*>BirdWeather controls are unavailable/,
  'an endpoint failure remains visible while the unavailable details panel is closed');
assert.match(birdweatherOff, /href="https:\/\/app\.birdweather\.com\/account\/stations"/,
  'BirdWeather account settings use the direct station-management link');

function birdweatherHarness(initialState, fetcher) {
  function node(attributes = {}) {
    const listeners = {};
    const attrs = { ...attributes };
    return {
      attrs,
      dataset: {},
      disabled: false,
      hidden: false,
      value: '',
      placeholder: '',
      textContent: '',
      children: [],
      focused: false,
      classList: { toggle() {} },
      addEventListener(type, listener) { (listeners[type] ||= []).push(listener); },
      dispatch(type, event = {}) {
        (listeners[type] || []).forEach((listener) => listener({
          preventDefault() {}, stopPropagation() {}, ...event,
        }));
      },
      getAttribute(name) { return attrs[name] ?? null; },
      setAttribute(name, value) { attrs[name] = String(value); },
      focus() { this.focused = true; },
      replaceChildren() { this.children = []; this.textContent = ''; },
      appendChild(child) { this.children.push(child); },
    };
  }

  const mainSwitch = node({ 'aria-checked': initialState.enabled ? 'true' : 'false' });
  const disclosure = node({ 'aria-expanded': initialState.enabled ? 'true' : 'false' });
  const details = node();
  details.hidden = !initialState.enabled;
  const tokenInput = node();
  const audioSwitch = node({ 'aria-checked': initialState.upload_audio ? 'true' : 'false' });
  const privacyButtons = [0, 1, 2, 3].map((level) => {
    const button = node({ 'aria-current': level === (initialState.privacy_threshold ?? 1) ? 'true' : 'false' });
    button.dataset.v = String(level);
    return button;
  });
  const privacy = node();
  privacy.querySelectorAll = (selector) => selector === 'button' ? privacyButtons : [];
  privacy.querySelector = (selector) => selector === 'button[aria-current="true"]'
    ? privacyButtons.find((button) => button.getAttribute('aria-current') === 'true')
    : null;
  const station = node();
  const status = node();
  const save = node();
  const forget = node();
  const selectors = {
    '[data-birdweather-toggle]': mainSwitch,
    '[data-birdweather-disclosure]': disclosure,
    '[data-birdweather-details]': details,
    '[data-birdweather-token]': tokenInput,
    '[data-birdweather-audio]': audioSwitch,
    '[data-birdweather-privacy]': privacy,
    '[data-birdweather-station]': station,
    '[data-birdweather-status]': status,
    '[data-birdweather-save]': save,
    '[data-birdweather-forget]': forget,
  };
  const control = node();
  control.querySelector = (selector) => selectors[selector] || null;
  const scope = { querySelector(selector) { return selector === '[data-birdweather-control]' ? control : null; } };
  const context = {
    adminFetch: fetcher,
    adminAuthCancelled() { return false; },
    confirm() { return true; },
    syncPill() {},
    document: { createElement() { return node(); } },
  };
  vm.createContext(context);
  vm.runInContext(functionSource('wireBirdweatherControl'), context);
  context.wireBirdweatherControl(scope, initialState);
  return { mainSwitch, details, tokenInput, station, status, forget };
}

function jsonResponse(status, body) {
  return { ok: status >= 200 && status < 300, status, json() { return Promise.resolve(body); } };
}

async function flushPromises() {
  for (let count = 0; count < 8; count += 1) await Promise.resolve();
}

const firstTokenPosts = [];
const firstTokenResponses = [
  jsonResponse(503, { ok: false, error: 'BirdWeather could not verify the station token' }),
  jsonResponse(200, {
    ok: true, enabled: true, token_configured: true, configuration_valid: true,
    upload_audio: false, privacy_threshold: 1,
    station: { state: 'connected', station_id: 222 },
  }),
];
const firstToken = birdweatherHarness({
  ok: true, enabled: false, token_configured: false,
  configuration_valid: true, upload_audio: false, privacy_threshold: 1,
}, (url, options = {}) => {
  assert.equal(options.method, 'POST', `unexpected first-token request: ${url}`);
  firstTokenPosts.push(JSON.parse(options.body));
  return Promise.resolve(firstTokenResponses.shift());
});
firstToken.mainSwitch.dispatch('click');
assert.equal(firstToken.mainSwitch.getAttribute('aria-checked'), 'false',
  'opening the first-token draft does not claim sharing is enabled');
assert.equal(firstToken.details.hidden, false, 'the first-token draft still expands');
firstToken.tokenInput.value = 'unverified-token';
firstToken.details.dispatch('submit');
await flushPromises();
assert.equal(firstTokenPosts[0].enabled, true, 'the draft asks the server to enable only with its token write');
assert.equal(firstToken.mainSwitch.getAttribute('aria-checked'), 'false',
  'failed or unavailable token verification leaves the backend-off switch visually off');
firstToken.tokenInput.value = 'verified-token';
firstToken.details.dispatch('submit');
await flushPromises();
assert.equal(firstToken.mainSwitch.getAttribute('aria-checked'), 'true',
  'the switch turns on only after the verified token save succeeds');

let resolveOldProbe;
const oldProbe = new Promise((resolve) => { resolveOldProbe = resolve; });
const stationRace = birdweatherHarness({
  ok: true, enabled: true, token_configured: true,
  configuration_valid: true, upload_audio: false, privacy_threshold: 1,
}, (url, options = {}) => {
  if (options.method === 'POST') {
    return Promise.resolve(jsonResponse(200, {
      ok: true, enabled: true, token_configured: true, configuration_valid: true,
      upload_audio: false, privacy_threshold: 1,
      station: { state: 'connected', station_id: 222 },
    }));
  }
  assert.match(url, /probe=1/);
  return oldProbe;
});
stationRace.tokenInput.value = 'replacement-token';
stationRace.details.dispatch('submit');
await flushPromises();
assert.equal(stationRace.station.children[0].href, 'https://app.birdweather.com/stations/222',
  'a successful replacement displays the newly verified station');
resolveOldProbe(jsonResponse(200, {
  ok: true, configuration_valid: true,
  station: { state: 'connected', station_id: 111 },
}));
await flushPromises();
assert.equal(stationRace.station.children[0].href, 'https://app.birdweather.com/stations/222',
  'an old-token probe cannot overwrite the replacement station link');

const disableRequests = [];
const disableResponses = [
  jsonResponse(200, {
    ok: true, enabled: false, token_configured: true, configuration_valid: true,
    upload_audio: false, privacy_threshold: 1,
  }),
  jsonResponse(200, {
    ok: true, enabled: false, token_configured: false, configuration_valid: true,
    upload_audio: false, privacy_threshold: 1,
  }),
];
const disableAndForget = birdweatherHarness({
  ok: true, enabled: true, token_configured: true,
  configuration_valid: true, upload_audio: false, privacy_threshold: 1,
}, (url, options = {}) => {
  if (options.method === 'POST') {
    disableRequests.push(JSON.parse(options.body));
    return Promise.resolve(disableResponses.shift());
  }
  return Promise.resolve(jsonResponse(200, {
    ok: true, configuration_valid: true,
    station: { state: 'connected', station_id: 222 },
  }));
});
disableAndForget.mainSwitch.dispatch('click');
assert.equal(disableAndForget.mainSwitch.getAttribute('aria-checked'), 'true',
  'a disable request keeps the persisted on-state visible while saving');
await flushPromises();
assert.equal(disableAndForget.mainSwitch.getAttribute('aria-checked'), 'false',
  'the switch turns off after the disable succeeds');
assert.equal(disableAndForget.details.hidden, true, 'successful disable closes details');
assert.equal(disableAndForget.forget.hidden, false, 'disabled configured station offers explicit token removal');
disableAndForget.forget.dispatch('click');
await flushPromises();
assert.equal(disableRequests[1].forget_token, true, 'forget uses the explicit credential-removal contract');
assert.equal(disableAndForget.mainSwitch.getAttribute('aria-checked'), 'false',
  'forgetting the token cannot enable sharing');

assert.match(html, /<div class="menu-footer">[\s\S]*id="adminLock" hidden[\s\S]*<\/div>/,
  'the lock action lives in the static footer and starts hidden');
assert.match(css, /\.menu-lock\s*\{[\s\S]*color:\s*var\(--danger\)/,
  'the footer lock action uses the restrained destructive color');
assert.match(css, /\.admin-settings input\.secret\s*\{[\s\S]*outline:\s*0/,
  'secret inputs suppress the browser blue outline');
assert.match(css, /\.admin-settings input\.secret:focus-visible\s*\{[\s\S]*var\(--ink-soft\)/,
  'secret inputs restore a theme-aware keyboard focus indicator');
assert.match(css, /\.password-change-form input:focus-visible,[\s\S]*var\(--ink-soft\)/,
  'password inputs use the same restrained theme-aware focus indicator');
assert.match(css, /\.settings-tip\s*\{[\s\S]*color:\s*var\(--ink-2\)/,
  'tooltip copy has stronger contrast than muted helper text');
assert.match(css, /\.access-copy\[data-tip-open="true"\] \.settings-tip/,
  'tooltip visibility follows the explicit open state');
assert.doesNotMatch(css, /\.access-copy:hover \.settings-tip/,
  'hover cannot independently reopen a tooltip after Escape');
assert.match(css, /\.menu-lock\s*\{[\s\S]*min-height:\s*24px/,
  'the footer lock action keeps a usable target height');

function tooltipHarness() {
  const buttonListeners = {};
  const documentListeners = {};
  const attrs = { 'aria-expanded': 'false' };
  const wrapperAttrs = {};
  const wrapper = {
    setAttribute(name, value) { wrapperAttrs[name] = String(value); },
    contains(value) { return value === button; },
  };
  const button = {
    addEventListener(type, listener) { (buttonListeners[type] ||= []).push(listener); },
    getAttribute(name) { return attrs[name] ?? null; },
    setAttribute(name, value) { attrs[name] = String(value); },
    closest(selector) { return selector === '.access-copy' ? wrapper : null; },
  };
  const documentStub = {
    activeElement: button,
    addEventListener(type, listener) { (documentListeners[type] ||= []).push(listener); },
    removeEventListener(type, listener) {
      documentListeners[type] = (documentListeners[type] || []).filter((item) => item !== listener);
    },
  };
  const scope = { querySelectorAll() { return [button]; } };
  const context = {
    document: documentStub,
    setTimeout(callback) { callback(); },
  };
  vm.createContext(context);
  vm.runInContext(`var settingsInfoCleanup = null; ${functionSource('wireSettingsInfo')}`, context);
  context.wireSettingsInfo(scope);
  return {
    attrs,
    wrapperAttrs,
    dispatchButton(type) {
      (buttonListeners[type] || []).forEach((listener) => listener({
        preventDefault() {}, stopPropagation() {},
      }));
    },
    dispatchDocument(type, event) {
      (documentListeners[type] || []).forEach((listener) => listener(event));
    },
  };
}

const tooltip = tooltipHarness();
tooltip.dispatchButton('pointerenter');
assert.equal(tooltip.attrs['aria-expanded'], 'true', 'pointer hover opens the tooltip explicitly');
tooltip.dispatchDocument('keydown', { key: 'Escape', stopPropagation() {} });
assert.equal(tooltip.attrs['aria-expanded'], 'false', 'Escape closes a hover-only tooltip without focus reopening it');
tooltip.dispatchButton('pointerleave');
tooltip.dispatchButton('pointerenter');
tooltip.dispatchButton('click');
assert.equal(tooltip.attrs['aria-expanded'], 'true', 'first click pins the visible tooltip');
tooltip.dispatchButton('click');
assert.equal(tooltip.attrs['aria-expanded'], 'false', 'second click dismisses the tooltip');

function segmentedControl(initial) {
  const listeners = [];
  const buttons = ['keep', 'purge'].map(function (value) {
    const attrs = {
      'aria-current': value === initial ? 'true' : 'false',
      'data-unavailable': null,
    };
    return {
      dataset: { v: value },
      disabled: false,
      getAttribute(name) { return attrs[name] ?? null; },
      setAttribute(name, next) { attrs[name] = String(next); },
    };
  });
  const container = {
    __advanceWired: false,
    querySelectorAll(selector) { return selector === 'button' ? buttons : []; },
    addEventListener(type, listener, capture) {
      assert.equal(type, 'click');
      listeners.push({ listener, capture: !!capture });
    },
  };
  function dispatch(button) {
    let stopped = false;
    const event = {
      target: { closest() { return button; } },
      stopImmediatePropagation() { stopped = true; },
    };
    listeners.filter(function (entry) { return entry.capture; })
      .forEach(function (entry) { if (!stopped) entry.listener(event); });
    if (stopped || !button) return;
    buttons.forEach(function (candidate) {
      candidate.setAttribute('aria-current', candidate === button ? 'true' : 'false');
    });
  }
  buttons.forEach(function (button) { button.click = function () { dispatch(button); }; });
  return { container, buttons, dispatch, listeners };
}

const segmentedContext = {};
vm.createContext(segmentedContext);
vm.runInContext(functionSource('wireToggleAdvance'), segmentedContext);
const disk = segmentedControl('keep');
segmentedContext.wireToggleAdvance(disk.container);
assert.equal(disk.listeners[0].capture, true,
  'two-option advance observes the old selection before the button handler runs');
disk.dispatch(disk.buttons[1]);
assert.equal(disk.buttons[1].getAttribute('aria-current'), 'true',
  'clicking Purge moves the disk selector to Purge');
disk.dispatch(disk.buttons[1]);
assert.equal(disk.buttons[0].getAttribute('aria-current'), 'true',
  'clicking the selected side advances the two-option selector');

let adminVisible = true;
let frame = null;
let packCount = 0;
const atlasContext = {
  document: {
    body: { classList: { contains() { return adminVisible; } } },
    getElementById() { return {}; },
  },
  requestAnimationFrame(callback) { frame = callback; return 1; },
  cancelAnimationFrame() { frame = null; },
  packAtlasGrids() { packCount += 1; },
};
vm.createContext(atlasContext);
vm.runInContext(`var atlasVisibilityPackFrame = 0; ${functionSource('queueVisibleAtlasPack')}`, atlasContext);
atlasContext.queueVisibleAtlasPack();
frame();
assert.equal(packCount, 0, 'Atlas does not measure while the admin overlay hides it');
adminVisible = false;
atlasContext.queueVisibleAtlasPack();
frame();
assert.equal(packCount, 1, 'Atlas repacks as soon as the admin overlay releases it');

function closeAdminPackCount(wasAdminOn, section) {
  let count = 0;
  const classes = new Set(wasAdminOn ? ['admin-on'] : []);
  const context = {
    document: { body: { classList: {
      contains(value) { return classes.has(value); },
      remove(value) { classes.delete(value); },
    } } },
    adminSect: section,
    adminViewGeneration: 0,
    adminEl: { setAttribute() {} },
    adminPollT: null,
    settingsInfoCleanup: null,
    discardPendingSettings() {},
    clearInterval() {},
    queueVisibleAtlasPack() { count += 1; },
  };
  vm.createContext(context);
  vm.runInContext(functionSource('closeAdmin'), context);
  context.closeAdmin();
  return count;
}
assert.equal(closeAdminPackCount(true, null), 1,
  'releasing an actual overlay repacks even if its section was cleared by a race');
assert.equal(closeAdminPackCount(false, null), 0,
  'ordinary non-admin hash navigation does not schedule an Atlas repack');

const gateSelectors = css.match(/[^{}]+\{/g) || [];
gateSelectors.forEach(function (selector) {
  if (!/body\.av-(?:local|forwarded)/.test(selector)) return;
  assert.doesNotMatch(selector, /atlas/i,
    'gate off and gate on must not select or reposition the Atlas');
});

assert.match(html, /styles\.css\?v=r175/, 'the polished CSS has a fresh cache key');
assert.match(html, /apt\.js\?v=r195/, 'the polished behavior has a fresh cache key');

console.log('admin UI polish smoke: ok');
