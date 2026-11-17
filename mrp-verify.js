/* MyRoute Pro: shared Google check code. Used by the Google Places / Address Verification tiles AND the Address Checker page,
   so both always give the same answers. It never holds a Google key: all Google calls go through the Supabase "places" function. */
(function () {
  var V = {};
  V.digits = function (t) { return String(t || '').replace(/\D/g, '').slice(-10); };
  V.norm = function (t) { return String(t || '').toLowerCase().replace(/&/g, 'and').replace(/\b(inc|llc|co|company|corp|the)\b/g, '').replace(/[^a-z0-9]+/g, ' ').trim(); };
  V.nameOk = function (a, b) { var x = V.norm(a), y = V.norm(b); if (!x || !y) return false; if (x === y || x.indexOf(y) > -1 || y.indexOf(x) > -1) return true; var xs = x.split(' '), ys = y.split(' '), hit = 0; xs.forEach(function (w) { if (w.length > 2 && ys.indexOf(w) > -1) hit++; }); return hit >= Math.min(2, xs.length); };
  V.mail = function (p) { return /\b(pmb|p\.?\s*o\.?\s*box|mailbox)\b/i.test(String(p.address || '') + ' ' + String(p.suite || '')) || /\b(ups store|fedex office|fedex ship|regus|mail boxes|mailbox|postal annex|pak mail|usps|post office)\b/i.test(String(p.name || '')); };
  V.pretty = function (t) { return String(t || '').replace(/_/g, ' '); };
  /* Warning flags for one Google place */
  V.flags = function (p) {
    var f = [], b = String(p.bad || '');
    if (b === 'police') f.push({ k: 'police', t: 'Police station' });
    else if (b === 'post_office') f.push({ k: 'post', t: 'Post office' });
    else if (b) f.push({ k: 'gov', t: V.pretty(b).replace(/^./, function (c) { return c.toUpperCase(); }) });
    if (/\bp\.?\s*o\.?\s*box\b/i.test(String(p.address || '') + ' ' + String(p.street || ''))) f.push({ k: 'pobox', t: 'P.O. box' });
    else if (V.mail(p) && b !== 'post_office') f.push({ k: 'mail', t: 'Mailbox / shipping store' });
    if (p.status === 'CLOSED_PERMANENTLY') f.push({ k: 'closed', t: 'Permanently closed' });
    else if (p.status === 'CLOSED_TEMPORARILY') f.push({ k: 'closed', t: 'Temporarily closed' });
    return f;
  };
  V.openText = function (p) { return p.status === 'OPERATIONAL' ? 'Open' : p.status === 'CLOSED_PERMANENTLY' ? 'Permanently closed' : p.status === 'CLOSED_TEMPORARILY' ? 'Temporarily closed' : 'Status not listed'; };
  /* Turn any function error into a clear sentence */
  V.explain = function (code, detail) {
    var d = String(detail || '');
    if (code === 'offline' || code === 'network') return 'Could not reach Google or Supabase. Check your connection and try again.';
    if (code === 401 || /not_signed_in/.test(d)) return 'You are signed out. Sign in again, then try again.';
    if (code === 403 || /not_allowed/.test(d)) return 'Your login is not allowed to run Google checks. Ask the administrator.';
    if (code === 404) return 'The "places" function is not deployed in Supabase yet.';
    if (/no_key/.test(d)) return 'The Google key (GOOGLE_PLACES_KEY) is not saved in Supabase yet.';
    if (/empty_query/.test(d)) return 'Type something to search for first.';
    return 'Google could not complete that check' + (d ? ' (' + d.slice(0, 120) + ')' : '') + '. Try again in a moment.';
  };
  /* invoke(name, body) -> Promise({data, error}) is supplied by each page (it owns the Supabase login) */
  V.call = async function (invoke, body) {
    var res;
    try { res = await invoke('places', body); } catch (e) { throw { code: 'network', message: V.explain('network') }; }
    if (res && res.error) {
      var ctx = res.error.context, code = ctx && ctx.status, txt = '';
      try { txt = JSON.stringify(await ctx.clone().json()); } catch (x) {}
      throw { code: code || 'error', message: V.explain(code, txt || res.error.message) };
    }
    if (!res || !res.data || res.data.error) throw { code: 'error', message: V.explain('error', res && res.data && res.data.error) };
    return res.data;
  };
  V.search = async function (invoke, query, loc) {
    var b = { query: String(query || '').trim() }; if (loc && loc.lat != null) { b.lat = loc.lat; b.lng = loc.lng; }
    var d = await V.call(invoke, b); return d.places || [];
  };
  /* Address Validation (falls back to Places inside the function if Google has not enabled it on the key) */
  V.validate = async function (invoke, address) { return V.call(invoke, { action: 'validate', address: String(address || '').trim() }); };
  /* Quick street comparison used for the Places fallback */
  V.streetKey = function (s) { return String(s || '').toLowerCase().replace(/\b(street)\b/g, 'st').replace(/\b(road)\b/g, 'rd').replace(/\b(drive)\b/g, 'dr').replace(/\b(avenue)\b/g, 'ave').replace(/\b(boulevard)\b/g, 'blvd').replace(/\b(highway)\b/g, 'hwy').replace(/\b(lane)\b/g, 'ln').replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim(); };
  /* Decide Verified / Review Needed from a validate() answer. Returns {status, reasons[], suggestion}. */
  V.judge = function (inputAddr, d) {
    var why = [], sug = null;
    if (d.mode === 'validation') {
      sug = d.formatted || null;
      if (!d.complete) why.push('Google says the address is incomplete');
      if (d.unconfirmed) why.push('Some parts of the address could not be confirmed');
      if (d.dpv && d.dpv !== 'Y') why.push(d.dpv === 'S' || d.dpv === 'D' ? 'The building is confirmed but the suite or unit is missing or not confirmed' : 'The US Postal Service does not recognize this delivery address');
      if (d.cmra) why.push('This is a mailbox or private mail-receiving store, not a business location');
      if (d.vacant) why.push('The US Postal Service lists it as vacant');
      if (d.granularity && !/PREMISE|SUB_PREMISE/.test(d.granularity)) why.push('Google could only match it to ' + V.pretty(d.granularity).toLowerCase() + ', not the exact building');
      if (d.changed) why.push('Google would write it differently (see the suggestion)');
    } else {
      var top = (d.places || [])[0];
      if (!top) { why.push('Google Places found nothing at this address'); }
      else {
        sug = top.address || null;
        var a = V.streetKey(inputAddr), s = V.streetKey(top.street);
        var num = (a.match(/^\d+/) || [''])[0];
        if (!s || !num || s.indexOf(num) !== 0 || a.indexOf(s.replace(/^\d+\s*/, '')) < 0) why.push('The closest Google result has a different street address');
        V.flags(top).forEach(function (f) { why.push(f.t); });
      }
    }
    return { status: why.length ? 'review' : 'verified', reasons: why, suggestion: sug };
  };
  /* Used by the Address Checker page: green / yellow / red for one saved stop */
  V.classify = function (rec, list) {
    var out = { level: 'red', why: [], pick: null, top: list[0] || null };
    var cand = list.filter(function (p) { return V.nameOk(rec.businessName, p.name); })[0];
    if (!cand) { out.why.push(list.length ? 'No Google listing with this name. Closest: ' + list[0].name + ' (' + list[0].address + ')' : 'Google found nothing'); return out; }
    out.pick = cand;
    var hard = [];
    if (cand.bad) hard.push('Google lists it as a ' + cand.bad.replace(/_/g, ' '));
    if (cand.status && cand.status !== 'OPERATIONAL') hard.push('Google says it is ' + cand.status.replace(/_/g, ' ').toLowerCase());
    if (V.mail(cand)) hard.push('Looks like a mailbox store or P.O. box');
    if (!cand.street) hard.push('No street address');
    if (hard.length) { out.why = hard; return out; }
    var soft = [];
    if (!cand.plumber) soft.push('Not listed as a plumber on Google (' + (cand.type || 'business').replace(/_/g, ' ') + ')');
    var fp = V.digits(rec.phone), gp = V.digits(cand.phone);
    if (!gp) soft.push('Google has no phone number for it');
    else if (!fp) soft.push('No phone in your file to compare');
    else if (fp !== gp) soft.push('Phone differs: file ' + rec.phone + ', Google ' + cand.phone);
    if (!cand.website && !(cand.ratings >= 1)) soft.push('No website and no reviews');
    out.level = soft.length ? 'yellow' : 'green'; out.why = soft; return out;
  };
  window.MRPVerify = V;
})();
