// OpenRCT2 agent plugin (QuickJS, ES2020). The host export orct2_agent_call runs
// __orct2_begin(json), flushes the game-action queue, then returns __orct2_end().
(function () {
  'use strict';

  var PLUGIN_NAME = 'orct2-agent';
  var API_VERSION = 124; // kPluginApiVersion in OpenRCT2 v0.5.6
  var EVENT_CAP = 500;

  // Required game-action parameters per C++ AcceptParameters (v0.5.6), x/y/z/direction and
  // x1..y2 expanded from the coordinate visitors. ":b" bool, ":s" string, otherwise integer.
  // An optional integer "flags" is accepted by every action.
  var ACTION_SPEC = {
    balloonpress: 'id',
    bannerplace: 'x y z direction object primaryColour',
    bannerremove: 'x y z direction',
    bannersetcolour: 'x y z direction primaryColour',
    bannersetname: 'id name:s',
    bannersetstyle: 'id type parameter',
    cheatset: 'type param1 param2',
    clearscenery: 'x1 y1 x2 y2 itemsToClear',
    footpathadditionplace: 'x y z object',
    footpathadditionremove: 'x y z',
    footpathlayoutplace: 'x y z slopeType slopeDirection object railingsObject edges constructFlags',
    footpathplace: 'x y z object railingsObject direction slopeType slopeDirection constructFlags',
    footpathremove: 'x y z',
    gamesetspeed: 'speed',
    guestsetflags: 'peep guestFlags',
    guestsetname: 'peep name:s',
    landbuyrights: 'x1 y1 x2 y2 setting',
    landlower: 'x y x1 y1 x2 y2 selectionType',
    landraise: 'x y x1 y1 x2 y2 selectionType',
    landsetheight: 'x y height style',
    landsetrights: 'x1 y1 x2 y2 setting ownership',
    landsmooth: 'x y x1 y1 x2 y2 selectionType isLowering:b',
    largesceneryplace: 'x y z direction object primaryColour secondaryColour tertiaryColour',
    largesceneryremove: 'x y z direction tileIndex',
    largescenerysetcolour: 'x y z direction tileIndex primaryColour secondaryColour tertiaryColour',
    loadorquit: 'mode savePromptMode',
    mapchangesize: 'targetSizeX targetSizeY shiftX shiftY',
    mazeplacetrack: 'x y z ride mazeEntry',
    mazesettrack: 'x y z direction ride mode isInitialPlacement:b',
    networkmodifygroup: 'type groupId name:s permissionIndex permissionState',
    parkentranceplace: 'x y z direction footpathSurfaceObject entranceObject footpathTypeIsLegacy:b',
    parkentranceremove: 'x y z',
    parkmarketing: 'type item duration',
    parksetdate: 'year month day',
    parksetentrancefee: 'value',
    parksetloan: 'value',
    parksetname: 'name:s',
    parksetparameter: 'parameter value',
    parksetresearchfunding: 'priorities fundingAmount',
    pausetoggle: '',
    peeppickup: 'type id x y z playerId',
    peepspawnplace: 'x y z direction',
    playerkick: 'playerId',
    playersetgroup: 'playerId groupId',
    ridecreate: 'rideType rideObject entranceObject colour1 colour2 inspectionInterval',
    ridedemolish: 'ride modifyType',
    rideentranceexitplace: 'x y direction ride station isExit:b',
    rideentranceexitremove: 'x y ride station isExit:b',
    ridefreezerating: 'ride type value',
    ridesetappearance: 'ride type value index',
    ridesetcolourscheme: 'x y z direction trackType colourScheme',
    ridesetname: 'ride name:s',
    ridesetprice: 'ride price isPrimaryPrice:b',
    ridesetsetting: 'ride setting value',
    ridesetstatus: 'ride status',
    ridesetvehicle: 'ride type value colour',
    scenariosetsetting: 'setting value',
    signsetname: 'id name:s',
    signsetstyle: 'id mainColour textColour isLarge:b',
    smallsceneryplace: 'x y z direction quadrant object primaryColour secondaryColour tertiaryColour',
    smallsceneryremove: 'x y z object quadrant',
    stafffire: 'id',
    staffhire: 'autoPosition:b staffType costumeIndex staffOrders',
    staffsetcolour: 'staffType colour',
    staffsetcostume: 'id costume',
    staffsetname: 'id name:s',
    staffsetorders: 'id staffOrders',
    staffsetpatrolarea: 'id x1 y1 x2 y2 mode',
    surfacesetstyle: 'x1 y1 x2 y2 surfaceStyle edgeStyle surfaceColour1 edgeColour1',
    tilemodify: 'x y setting value1 value2',
    trackdesign: 'x y z direction',
    trackplace: 'x y z direction ride trackType rideType brakeSpeed colour seatRotation trackPlaceFlags isFromTrackDesign:b',
    trackremove: 'x y z direction trackType sequence',
    tracksetbrakespeed: 'x y z trackType brakeSpeed',
    wallplace: 'x y z object edge primaryColour secondaryColour tertiaryColour',
    wallremove: 'x y z direction',
    wallsetcolour: 'x y z direction primaryColour secondaryColour tertiaryColour',
    waterlower: 'x1 y1 x2 y2',
    waterraise: 'x1 y1 x2 y2',
    watersetheight: 'x y height',
  };

  var ACTION_STATUS = {
    0: 'ok', 1: 'invalidParameters', 2: 'disallowed', 3: 'gamePaused', 4: 'insufficientFunds',
    5: 'notInEditorMode', 6: 'notOwned', 7: 'tooLow', 8: 'tooHigh', 9: 'noClearance',
    10: 'itemAlreadyPlaced', 11: 'notClosed', 12: 'broken', 13: 'noFreeElements', 65535: 'unknown',
  };
  var EXPENDITURE_TYPES = [
    'ride_construction', 'ride_runningcosts', 'land_purchase', 'landscaping', 'park_entrance_tickets',
    'park_ride_tickets', 'shop_sales', 'shop_stock', 'food_drink_sales', 'food_drink_stock', 'wages',
    'marketing', 'research', 'interest',
  ];
  var RIDE_STATUS = { closed: 0, open: 1, testing: 2, simulating: 3 };
  var STAFF_TYPE = { handyman: 0, mechanic: 1, security: 2, entertainer: 3 };
  // Handyman: sweep|water|bins (1|2|4); mechanic: inspect|fix (1|2).
  var STAFF_ORDERS = [7, 3, 0, 0];

  var ACTIONS = {};
  Object.keys(ACTION_SPEC).forEach(function (name) {
    ACTIONS[name] = ACTION_SPEC[name].split(' ').filter(Boolean).map(function (p) {
      var parts = p.split(':');
      return { name: parts[0], type: parts[1] === 'b' ? 'bool' : parts[1] === 's' ? 'string' : 'int' };
    });
  });

  class AgentError extends Error {
    constructor(code, message, details, extra) {
      super(message);
      this.code = code;
      this.details = details || {};
      this.extra = extra || {};
    }
  }

  var current = null;
  var events = [];
  var eventCounter = 0;
  var lastMessageSig = null;

  // ---- helpers -----------------------------------------------------------

  function has(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
  }

  function toArray(a) {
    var out = [];
    if (a === null || a === undefined) return out;
    for (var i = 0; i < a.length; i++) out.push(a[i]);
    return out;
  }

  function pick(obj, keys) {
    var out = {};
    if (obj === null || obj === undefined) return out;
    keys.forEach(function (k) {
      try {
        var v = obj[k];
        if (v !== undefined) out[k] = v === null ? null : v;
      } catch (e) { /* property unavailable for this entity */ }
    });
    return out;
  }

  function point(c) {
    if (!c) return null;
    var out = { x: c.x, y: c.y };
    if (c.z !== undefined) out.z = c.z;
    if (c.direction !== undefined) out.direction = c.direction;
    return out;
  }

  function plain(v, depth) {
    if (v === null || v === undefined) return null;
    var t = typeof v;
    if (t === 'number') return isFinite(v) ? v : String(v);
    if (t === 'string' || t === 'boolean') return v;
    if (t === 'bigint') return String(v);
    if (t === 'function' || t === 'symbol') return '[' + t + ']';
    if (depth >= 4) return '[depth]';
    if (Array.isArray(v) || ArrayBuffer.isView(v)) {
      return Array.prototype.slice.call(v, 0, 200).map(function (x) { return plain(x, depth + 1); });
    }
    var out = {};
    var seen = {};
    for (var o = v; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
      Object.getOwnPropertyNames(o).forEach(function (name) {
        if (name === 'constructor' || seen[name]) return;
        seen[name] = true;
        var d = Object.getOwnPropertyDescriptor(o, name);
        if (d && typeof d.value === 'function') return;
        try { out[name] = plain(v[name], depth + 1); } catch (e) { /* write-only or throwing accessor */ }
      });
    }
    return out;
  }

  function safeName(value, ext, fallback) {
    var name = value === undefined || value === null ? fallback : String(value);
    if (name.toLowerCase().slice(-ext.length) === ext) name = name.slice(0, -ext.length);
    if (!/^[A-Za-z0-9][A-Za-z0-9._ -]{0,95}$/.test(name) || name.indexOf('..') >= 0) {
      throw new AgentError('invalid_args', 'filename must match [A-Za-z0-9][A-Za-z0-9._ -]{0,95} (no path separators)', { missing: [], invalid: [{ name: 'filename', expected: 'plain file name' }] });
    }
    return name + ext;
  }

  function intArg(req, key, def, min, max) {
    var v = req[key];
    if (v === undefined || v === null) return def;
    if (typeof v === 'string' && v.trim() !== '') v = Number(v);
    if (typeof v !== 'number' || !isFinite(v) || Math.floor(v) !== v || v < min || v > max) {
      throw new AgentError('invalid_args', key + ' must be an integer in ' + min + '..' + max, { missing: [], invalid: [{ name: key, expected: 'integer ' + min + '..' + max }] });
    }
    return v;
  }

  function requireString(req, key) {
    if (typeof req[key] !== 'string' || req[key] === '') {
      throw new AgentError('invalid_args', key + ' is required', { missing: [key] });
    }
    return req[key];
  }

  function ensureReady() {
    if (typeof park === 'undefined' || typeof map === 'undefined' || typeof context === 'undefined' || typeof date === 'undefined') {
      throw new AgentError('not_ready', 'game globals are not available yet');
    }
  }

  function tickNow() {
    try { return date.ticksElapsed; } catch (e) { return null; }
  }

  function pausedNow() {
    try { return context.paused; } catch (e) { return null; }
  }

  // ---- game actions ------------------------------------------------------

  function suggest(name) {
    var q = String(name).toLowerCase();
    return Object.keys(ACTIONS).filter(function (k) { return k.indexOf(q) >= 0 || q.indexOf(k) >= 0; }).slice(0, 8);
  }

  function validateArgs(action, raw) {
    if (typeof action !== 'string' || !has(ACTIONS, action)) {
      throw new AgentError('unknown_action', 'unknown game action ' + JSON.stringify(action), { suggestions: typeof action === 'string' ? suggest(action) : [] });
    }
    if (raw === undefined || raw === null) raw = {};
    if (typeof raw !== 'object' || Array.isArray(raw)) {
      throw new AgentError('invalid_args', 'args must be an object', { missing: [] });
    }
    var spec = ACTIONS[action];
    var args = {};
    var missing = [];
    var invalid = [];
    spec.forEach(function (p) {
      var v = raw[p.name];
      if (v === undefined || v === null) { missing.push(p.name); return; }
      if (p.type === 'bool') {
        if (v === 'true' || v === 1) v = true;
        else if (v === 'false' || v === 0) v = false;
        if (typeof v !== 'boolean') { invalid.push({ name: p.name, expected: 'boolean' }); return; }
      } else if (p.type === 'string') {
        if (typeof v !== 'string') { invalid.push({ name: p.name, expected: 'string' }); return; }
      } else {
        if (typeof v === 'string' && v.trim() !== '') v = Number(v);
        if (typeof v !== 'number' || !isFinite(v)) { invalid.push({ name: p.name, expected: 'integer' }); return; }
      }
      args[p.name] = v;
    });
    if (raw.flags !== undefined && raw.flags !== null) args.flags = raw.flags;
    if (missing.length || invalid.length) {
      var parts = [];
      if (missing.length) parts.push('missing: ' + missing.join(', '));
      if (invalid.length) parts.push('invalid: ' + invalid.map(function (i) { return i.name + ' (expected ' + i.expected + ')'; }).join(', '));
      throw new AgentError('invalid_args', action + ' ' + parts.join('; '), {
        missing: missing, invalid: invalid,
        required: spec.map(function (p) { return p.name + (p.type === 'int' ? '' : ':' + p.type); }),
      });
    }
    return args;
  }

  function copyResult(res) {
    var out = { error: 0 };
    if (!res) return out;
    ['error', 'errorTitle', 'errorMessage', 'cost', 'expenditureType', 'ride', 'peep', 'bannerIndex'].forEach(function (k) {
      if (res[k] !== undefined && res[k] !== null) out[k] = res[k];
    });
    if (res.position) out.position = point(res.position);
    return out;
  }

  function failedAction(action, phase, res, query, executed) {
    var status = res.error;
    var name = has(ACTION_STATUS, status) ? ACTION_STATUS[status] : 'status' + status;
    var message = action + ' ' + phase + ' failed: ' + (res.errorTitle ? res.errorTitle : name) + (res.errorMessage ? ' - ' + res.errorMessage : '');
    var details = { status: status, statusName: name, phase: phase };
    if (status === 3) details.hint = 'game is paused; run pause with paused=false first';
    return new AgentError('action_failed', message, details, { query: query, executed: executed });
  }

  function runQuery(action, args) {
    var result = null;
    try {
      context.queryAction(action, args, function (res) { result = copyResult(res); });
    } catch (e) {
      throw new AgentError('action_rejected', action + ' query threw: ' + (e && e.message ? e.message : e));
    }
    if (result === null) throw new AgentError('exception', action + ' query returned no result');
    return result;
  }

  // Returns a finalizer evaluated after the host has flushed the action queue.
  function runAction(action, rawArgs, dryRun) {
    var args = validateArgs(action, rawArgs);
    var query = runQuery(action, args);
    if (query.error) throw failedAction(action, 'query', query, query, null);
    if (dryRun) {
      return function () { return { action: action, dryRun: true, query: query, executed: null }; };
    }
    var executed = null;
    try {
      context.executeAction(action, args, function (res) { executed = copyResult(res); });
    } catch (e) {
      throw new AgentError('action_rejected', action + ' execute threw: ' + (e && e.message ? e.message : e), { query: query });
    }
    return function () {
      if (executed && executed.error) throw failedAction(action, 'execute', executed, query, executed);
      var body = { action: action, query: query, executed: executed };
      if (executed === null) body.queued = true;
      return body;
    };
  }

  function defaultCostume(staffType) {
    try {
      var want = ['handyman', 'mechanic', 'security', 'entertainer'][staffType];
      var objs = objectManager.getAllObjects('peep_animations');
      for (var i = 0; i < objs.length; i++) {
        if (objs[i] && String(objs[i].identifier).indexOf(want) >= 0) return objs[i].index;
      }
    } catch (e) { /* fall through to index 0 */ }
    return 0;
  }

  function mapped(table, v, label) {
    if (typeof v === 'string' && has(table, v)) return table[v];
    if (typeof v === 'string' && v.trim() !== '' && !isNaN(Number(v))) return Number(v);
    if (typeof v === 'number') return v;
    if (v === undefined || v === null) return undefined;
    throw new AgentError('invalid_args', label + ' must be one of ' + Object.keys(table).join('|') + ' or its number', { missing: [], invalid: [{ name: label, expected: Object.keys(table).join('|') }] });
  }

  function firstDefined() {
    for (var i = 0; i < arguments.length; i++) if (arguments[i] !== undefined && arguments[i] !== null) return arguments[i];
    return undefined;
  }

  var ALIASES = {
    'park.open': function () { return { action: 'parksetparameter', args: { parameter: 1, value: 0 } }; },
    'park.close': function () { return { action: 'parksetparameter', args: { parameter: 0, value: 0 } }; },
    'park.fee': function (r) { return { action: 'parksetentrancefee', args: { value: firstDefined(r.value, r.fee) } }; },
    'ride.price': function (r) {
      var primary = firstDefined(r.isPrimaryPrice, r.primary, true);
      return { action: 'ridesetprice', args: { ride: r.ride, price: r.price, isPrimaryPrice: primary } };
    },
    'ride.status': function (r) {
      return { action: 'ridesetstatus', args: { ride: r.ride, status: mapped(RIDE_STATUS, r.status, 'status') } };
    },
    'staff.hire': function (r) {
      var type = mapped(STAFF_TYPE, firstDefined(r.staffType, r.type), 'staffType');
      var args = { autoPosition: firstDefined(r.autoPosition, true), staffType: type };
      if (type !== undefined) {
        args.costumeIndex = firstDefined(r.costumeIndex, defaultCostume(type));
        args.staffOrders = firstDefined(r.staffOrders, STAFF_ORDERS[type] === undefined ? 0 : STAFF_ORDERS[type]);
      }
      return { action: 'staffhire', args: args };
    },
  };

  // ---- verbs -------------------------------------------------------------

  var RIDE_KEYS = ['id', 'name', 'type', 'classification', 'status', 'excitement', 'intensity', 'nausea',
    'totalCustomers', 'guestCount', 'downtime', 'reliability', 'satisfaction', 'incomePerHour', 'profit',
    'runningCost', 'totalProfit', 'value', 'age', 'buildDate', 'inspectionInterval', 'isEmpty'];
  var RIDE_DETAIL_KEYS = ['mode', 'flags', 'lifecycleFlags', 'minimumWaitingTime', 'maximumWaitingTime', 'liftHillSpeed',
    'maxSpeed', 'averageSpeed', 'rideTime', 'rideLength', 'maxPositiveVerticalGs', 'maxNegativeVerticalGs',
    'maxLateralGs', 'totalAirTime', 'numDrops', 'numLiftHills', 'highestDropHeight', 'stationStyle', 'music'];

  function copyRide(ride, detail) {
    var out = pick(ride, RIDE_KEYS);
    out.price = toArray(ride.price);
    out.breakdown = ride.breakdown === undefined ? null : ride.breakdown;
    try { out.object = { identifier: ride.object.identifier, name: ride.object.name }; } catch (e) { out.object = null; }
    if (detail) {
      Object.assign(out, pick(ride, RIDE_DETAIL_KEYS));
      out.vehicles = toArray(ride.vehicles);
      out.stations = toArray(ride.stations).map(function (s) {
        return { start: point(s.start), length: s.length, entrance: point(s.entrance), exit: point(s.exit), queueTime: s.queueTime };
      });
    }
    return out;
  }

  function thoughtTypes(guest) {
    return toArray(guest.thoughts).map(function (t) { return String(t.type); });
  }

  function copyGuest(g, full) {
    var out = pick(g, ['id', 'name', 'x', 'y', 'z', 'happiness', 'hunger', 'thirst', 'nausea', 'toilet', 'cash', 'isInPark', 'isLost']);
    out.thoughts = thoughtTypes(g);
    if (full) {
      Object.assign(out, pick(g, ['energy', 'happinessTarget', 'nauseaTarget', 'minIntensity', 'maxIntensity', 'nauseaTolerance', 'favouriteRide', 'tshirtColour', 'trousersColour']));
      out.items = toArray(g.items).map(function (i) { return String(i.type !== undefined ? i.type : i); });
      out.thoughtText = toArray(g.thoughts).map(function (t) { try { return t.toString(); } catch (e) { return String(t.type); } });
    }
    return out;
  }

  function allStaff() {
    return toArray(map.getAllEntities('staff'));
  }

  var OBJECTIVE_KEYS = ['type', 'guests', 'year', 'length', 'excitement', 'parkValue', 'monthlyIncome'];

  function verbStatus(req) {
    var include = Array.isArray(req.include) ? req.include : [];
    var body = {
      speed: context.gameSpeed,
      mode: context.mode,
      date: { year: date.year, month: date.month, day: date.day, monthsElapsed: date.monthsElapsed },
      park: {
        name: park.name, open: park.getFlag('open'), cash: park.cash, loan: park.bankLoan, maxLoan: park.maxBankLoan,
        rating: park.rating, value: park.value, companyValue: park.companyValue, guests: park.guests,
        entranceFee: park.entranceFee, parkSize: park.parkSize,
      },
      scenario: { name: scenario.name, status: scenario.status, objective: pick(scenario.objective, OBJECTIVE_KEYS) },
      climate: { type: climate.type, now: pick(climate.current, ['weather', 'temperature']), next: pick(climate.future, ['weather', 'temperature']) },
      research: { funding: park.research.funding, stage: park.research.stage, progress: park.research.progress },
      counts: { rides: map.numRides, staff: allStaff().length },
    };
    if (include.indexOf('finance') >= 0) {
      var fin = {};
      EXPENDITURE_TYPES.forEach(function (t) { fin[t] = toArray(park.getMonthlyExpenditure(t)); });
      body.finance = {
        monthlyExpenditure: fin,
        totalAdmissions: park.totalAdmissions,
        totalIncomeFromAdmissions: park.totalIncomeFromAdmissions,
      };
    }
    if (include.indexOf('messages') >= 0) {
      body.messages = toArray(park.messages).slice(0, 20).map(function (m) { return pick(m, ['type', 'text', 'subject', 'month', 'day']); });
    }
    if (include.indexOf('awards') >= 0) {
      body.awards = toArray(park.awards).map(function (a) { return pick(a, ['type', 'monthsRemaining']); });
    }
    return body;
  }

  function verbRides(req) {
    if (req.id !== undefined && req.id !== null) {
      var id = intArg(req, 'id', 0, 0, 65535);
      var ride = map.getRide(id);
      if (!ride) throw new AgentError('not_found', 'no ride with id ' + id, { id: id });
      return { rides: [copyRide(ride, req.detail !== false)] };
    }
    return { rides: toArray(map.rides).map(function (r) { return copyRide(r, req.detail === true); }) };
  }

  function verbGuests(req) {
    if (req.id !== undefined && req.id !== null) {
      var id = intArg(req, 'id', 0, 0, 65535);
      var e = map.getEntity(id);
      if (!e || e.type !== 'guest') throw new AgentError('not_found', 'no guest with id ' + id, { id: id });
      return { guest: copyGuest(e, true) };
    }
    var sample = intArg(req, 'sample', 5, 0, 100);
    var guests = toArray(map.getAllEntities('guest'));
    var sum = { happiness: 0, hunger: 0, thirst: 0, nausea: 0, toilet: 0, cash: 0 };
    var inPark = 0;
    var lost = 0;
    var thoughts = {};
    var worst = [];
    guests.forEach(function (g) {
      if (!g.isInPark) return;
      inPark++;
      if (g.isLost) lost++;
      Object.keys(sum).forEach(function (k) { sum[k] += g[k]; });
      var types = thoughtTypes(g);
      types.forEach(function (t) { thoughts[t] = (thoughts[t] || 0) + 1; });
      worst.push({ id: g.id, happiness: g.happiness, thought: types.length ? types[0] : null });
    });
    var avg = {};
    Object.keys(sum).forEach(function (k) { avg[k] = inPark ? Math.round(sum[k] / inPark) : 0; });
    worst.sort(function (a, b) { return a.happiness - b.happiness; });
    return { count: guests.length, inPark: inPark, lost: lost, avg: avg, thoughts: thoughts, worst: worst.slice(0, sample) };
  }

  function verbStaff() {
    return {
      staff: allStaff().map(function (s) {
        var out = pick(s, ['id', 'name', 'staffType', 'x', 'y', 'z', 'orders', 'colour']);
        try { out.costume = s.costume; } catch (e) { out.costume = null; }
        return out;
      }),
    };
  }

  function verbMap(req) {
    var size = map.size;
    var x0 = intArg(req, 'x', 0, 0, size.x - 1);
    var y0 = intArg(req, 'y', 0, 0, size.y - 1);
    var w = intArg(req, 'w', 16, 1, 1024);
    var h = intArg(req, 'h', 16, 1, 1024);
    if (w * h > 1024) throw new AgentError('invalid_args', 'w*h must be <= 1024 tiles', { missing: [], invalid: [{ name: 'w,h', expected: 'w*h<=1024' }] });
    w = Math.min(w, size.x - x0);
    h = Math.min(h, size.y - y0);
    var surface = [];
    var water = [];
    var own = [];
    var elements = [];
    for (var y = y0; y < y0 + h; y++) {
      var srow = [];
      var wrow = [];
      var orow = [];
      for (var x = x0; x < x0 + w; x++) {
        var els = toArray(map.getTile(x, y).elements);
        var sBh = null;
        var wBh = 0;
        var o = 0;
        els.forEach(function (el) {
          if (el.type === 'surface') {
            sBh = el.baseHeight;
            wBh = el.waterHeight;
            o = el.hasOwnership ? 1 : el.hasConstructionRights ? 2 : 0;
            return;
          }
          var e = { x: x, y: y, t: el.type, bh: el.baseHeight, ch: el.clearanceHeight };
          if (el.isGhost) e.ghost = true;
          if (el.type === 'footpath') {
            e.queue = el.isQueue;
            if (el.ride !== null && el.ride !== undefined) e.ride = el.ride;
          } else if (el.type === 'track') {
            e.ride = el.ride; e.trackType = el.trackType; e.dir = el.direction; e.seq = el.sequence;
          } else if (el.type === 'entrance') {
            e.ride = el.ride; e.station = el.station; e.dir = el.direction; e.seq = el.sequence;
          } else {
            Object.assign(e, pick(el, ['object', 'direction']));
          }
          elements.push(e);
        });
        srow.push(sBh);
        wrow.push(wBh);
        orow.push(o);
      }
      surface.push(srow);
      water.push(wrow);
      own.push(orow);
    }
    return { size: point(size), origin: { x: x0, y: y0 }, w: w, h: h, surface: surface, water: water, own: own, elements: elements };
  }

  function verbObjects(req) {
    var type = req.type === undefined ? 'ride' : String(req.type);
    var offset = intArg(req, 'offset', 0, 0, 1000000);
    var limit = intArg(req, 'limit', 100, 1, 500);
    var rows;
    if (req.installed === true) {
      rows = toArray(objectManager.installedObjects).filter(function (o) { return o.type === type; }).map(function (o) {
        return { identifier: o.identifier, name: o.name, type: o.type, sourceGames: toArray(o.sourceGames) };
      });
    } else {
      rows = toArray(objectManager.getAllObjects(type)).filter(Boolean).map(function (o) {
        var out = { index: o.index, identifier: o.identifier, name: o.name };
        if (type === 'ride') {
          try { out.rideType = toArray(o.rideType); } catch (e) { out.rideType = []; }
        }
        return out;
      });
    }
    return { type: type, installed: req.installed === true, total: rows.length, offset: offset, objects: rows.slice(offset, offset + limit) };
  }

  function verbEvents(req) {
    var since = intArg(req, 'since', 0, 0, Number.MAX_SAFE_INTEGER);
    var limit = intArg(req, 'limit', 50, 1, EVENT_CAP);
    var fresh = events.filter(function (e) { return e.n > since; });
    var oldest = events.length ? events[0].n : eventCounter + 1;
    var page = fresh.slice(0, limit);
    return {
      events: page,
      next: page.length ? page[page.length - 1].n : since,
      latest: eventCounter,
      dropped: since + 1 < oldest && eventCounter > 0,
    };
  }

  function verbAct(req) {
    return runAction(req.action, req.args, req.dryRun === true);
  }

  function makeAlias(name) {
    return function (req) {
      var spec = ALIASES[name](req);
      var fin = runAction(spec.action, spec.args, req.dryRun === true);
      return function () {
        var body = fin();
        body.alias = name;
        return body;
      };
    };
  }

  function verbActions(req) {
    var describe = function (name) {
      return ACTIONS[name].map(function (p) { return p.name + (p.type === 'int' ? '' : ':' + p.type); });
    };
    if (req.action !== undefined) {
      if (!has(ACTIONS, req.action)) throw new AgentError('unknown_action', 'unknown game action ' + JSON.stringify(req.action), { suggestions: suggest(req.action) });
      return { actions: { [req.action]: describe(req.action) } };
    }
    var all = {};
    Object.keys(ACTIONS).sort().forEach(function (n) { all[n] = describe(n); });
    return { actions: all };
  }

  function verbPause(req) {
    if (req.paused !== undefined && req.paused !== null) {
      if (typeof req.paused !== 'boolean') throw new AgentError('invalid_args', 'paused must be a boolean', { missing: [], invalid: [{ name: 'paused', expected: 'boolean' }] });
      context.paused = req.paused;
    }
    return function () { return { paused: context.paused }; };
  }

  function verbSpeed(req) {
    if (req.speed === undefined || req.speed === null) return { speed: context.gameSpeed };
    var speed = intArg(req, 'speed', 1, 1, 4);
    var fin = runAction('gamesetspeed', { speed: speed }, false);
    return function () {
      var body = fin();
      body.speed = context.gameSpeed;
      return body;
    };
  }

  function verbSave(req) {
    var name = safeName(req.filename, '.park', 'agent').slice(0, -'.park'.length);
    context.saveGame({ filename: name });
    return { path: 'save/' + name + '.park', filename: name };
  }

  function verbScreenshot(req) {
    var name = safeName(req.filename, '.png', 'orct2-' + tickNow());
    var zoom = intArg(req, 'zoom', 0, 0, 3);
    var rotation = intArg(req, 'rotation', 0, 0, 3);
    var opts = { filename: name, zoom: zoom, rotation: rotation };
    var out = { path: 'screenshot/' + name, filename: name, zoom: zoom, rotation: rotation };
    if (req.full === true) {
      out.full = true;
    } else {
      var pos = req.position;
      var size = map.size;
      var px = pos && pos.x !== undefined ? pos.x : size.x * 16;
      var py = pos && pos.y !== undefined ? pos.y : size.y * 16;
      var width = intArg(req, 'width', 1024, 16, 4096);
      var height = intArg(req, 'height', 768, 16, 4096);
      opts.position = { x: px, y: py };
      opts.width = width;
      opts.height = height;
      out.position = opts.position;
      out.width = width;
      out.height = height;
    }
    if (req.transparent === true) opts.transparent = true;
    context.captureImage(opts);
    return out;
  }

  function verbEval(req) {
    requireString(req, 'js');
    var value = (0, eval)(req.js);
    return { value: plain(value, 0) };
  }

  var VERBS = {
    status: verbStatus,
    rides: verbRides,
    guests: verbGuests,
    staff: verbStaff,
    map: verbMap,
    objects: verbObjects,
    events: verbEvents,
    act: verbAct,
    actions: verbActions,
    pause: verbPause,
    speed: verbSpeed,
    save: verbSave,
    screenshot: verbScreenshot,
    eval: verbEval,
  };
  Object.keys(ALIASES).forEach(function (name) { VERBS[name] = makeAlias(name); });

  // ---- begin / end protocol ---------------------------------------------

  function envelope(ok) {
    return { ok: ok, tick: tickNow(), paused: pausedNow() };
  }

  function success(body) {
    return Object.assign(envelope(true), body);
  }

  function failure(err) {
    var out = envelope(false);
    if (err instanceof AgentError) {
      out.error = Object.assign({ code: err.code, message: err.message }, err.details);
      Object.assign(out, err.extra);
    } else {
      out.error = { code: 'exception', message: err && err.message ? err.message : String(err) };
    }
    return out;
  }

  globalThis.__orct2_begin = function (json) {
    current = { finalize: null, result: null, error: null };
    try {
      var req = JSON.parse(json);
      if (req === null || typeof req !== 'object' || Array.isArray(req) || typeof req.v !== 'string') {
        throw new AgentError('invalid_args', 'request must be an object with a string field "v"', { missing: ['v'] });
      }
      if (!has(VERBS, req.v)) {
        throw new AgentError('unknown_verb', 'unknown verb ' + JSON.stringify(req.v), { verbs: Object.keys(VERBS) });
      }
      ensureReady();
      var out = VERBS[req.v](req);
      if (typeof out === 'function') current.finalize = out;
      else current.result = out;
    } catch (e) {
      current.error = e;
    }
  };

  globalThis.__orct2_end = function () {
    var cur = current;
    current = null;
    try {
      if (cur === null) throw new AgentError('not_ready', '__orct2_end called without __orct2_begin');
      if (cur.error) throw cur.error;
      return JSON.stringify(success(cur.finalize ? cur.finalize() : cur.result));
    } catch (e) {
      return JSON.stringify(failure(e));
    }
  };

  // ---- events ------------------------------------------------------------

  function pushEvent(type, fields) {
    eventCounter++;
    events.push(Object.assign({ n: eventCounter, tick: tickNow(), type: type }, fields));
    if (events.length > EVENT_CAP) events.splice(0, events.length - EVENT_CAP);
  }

  function messageSig(m) {
    return [m.month, m.day, m.tickCount, m.text].join('/');
  }

  function collectMessages() {
    var msgs = toArray(park.messages);
    if (!msgs.length) { lastMessageSig = null; return; }
    var fresh = [];
    for (var i = 0; i < msgs.length && i < 10; i++) {
      if (messageSig(msgs[i]) === lastMessageSig) break;
      fresh.push(msgs[i]);
    }
    lastMessageSig = messageSig(msgs[0]);
    fresh.reverse().forEach(function (m) { pushEvent('park.message', Object.assign(pick(m, ['text', 'subject']), { messageType: m.type })); });
  }

  function subscribe(hook, fn) {
    try { context.subscribe(hook, fn); } catch (e) { console.log('[' + PLUGIN_NAME + '] cannot subscribe ' + hook + ': ' + e.message); }
  }

  function main() {
    subscribe('interval.day', function () {
      pushEvent('day', { date: { year: date.year, month: date.month, day: date.day } });
      collectMessages();
    });
    subscribe('action.execute', function (e) {
      var fields = { action: e.action, player: e.player, error: e.result && e.result.error ? e.result.error : 0 };
      try { fields.args = JSON.parse(JSON.stringify(e.args)); } catch (err) { /* non-serialisable args */ }
      pushEvent('action', fields);
    });
    subscribe('ride.breakdown', function (e) { pushEvent('ride.breakdown', { ride: e.rideId, reason: e.breakdownReason }); });
    subscribe('vehicle.crash', function (e) { pushEvent('vehicle.crash', { id: e.id, crashIntoType: e.crashIntoType }); });
    subscribe('map.changed', function () { lastMessageSig = null; pushEvent('map.changed', {}); });
    console.log('[' + PLUGIN_NAME + '] ready (' + Object.keys(VERBS).length + ' verbs, ' + Object.keys(ACTIONS).length + ' actions)');
  }

  registerPlugin({
    name: PLUGIN_NAME,
    version: '1.0',
    authors: ['ocasazza'],
    type: 'intransient',
    licence: 'MIT',
    targetApiVersion: API_VERSION,
    main: main,
  });
})();
