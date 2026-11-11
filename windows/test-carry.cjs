// Run with node --test test-carry.cjs from windows/.
// The carry overlay's own arithmetic: the spring the notch follows the hand on, and the border it
// travels. The Mac's FollowSpringTests and BorderTrackTests, against carry.html's script.
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, 'codenotch/ui/carry.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function page() {
  const element = () => ({ style: {}, children: [], setAttribute() {}, querySelector: () => element(), set innerHTML(_) {} });
  const context = vm.createContext({
    window: { __TAURI__: { core: { invoke: () => Promise.resolve(null) }, event: { listen: () => Promise.resolve() } } },
    document: { getElementById: element },
    matchMedia: () => ({ matches: false }),
    requestAnimationFrame() {},
    Math,
  });
  vm.runInContext(script, context);
  vm.runInContext(`st = { w: 1800, h: 1169, reach: 325, size: 1, edge: 'top', shape: {
    radius: 20, fillet: 38.7,
    upright: { depth: 70, length: 300, pitch: 84, inset: 34.5 },
    flat: { depth: 95, length: 200, pitch: 58, inset: 47.5 },
  } }`, context);
  return (source) => vm.runInContext(source, context);
}

test('following the hand is brisk and all but dead; coming to rest gives a little and settles', () => {
  const run = page();
  const follow = (spring, fps) => run(`(() => {
    const target = 100, dt = 1 / ${fps};
    let position = 0, velocity = 0, furthest = 0, settledBy = null;
    for (let frame = 0; frame < ${fps} * 2; frame++) {
      const step = spring(target - position, velocity, dt, ${spring});
      position += step.moved; velocity = step.velocity;
      furthest = Math.max(furthest, position);
      if (settledBy === null && Math.abs(target - position) < .3 && Math.abs(velocity) < 6) settledBy = (frame + 1) * dt;
    }
    return { overshoot: furthest - target, settledBy };
  })()`);
  for (const fps of [60, 120]) {
    const hand = follow('FOLLOW', fps);
    assert.ok(hand.overshoot < 2, `${fps}fps: it swings past the hand`);
    assert.ok(hand.settledBy !== null && hand.settledBy < .5, `${fps}fps: it lags the hand`);
    const rest = follow('SETTLE', fps);
    assert.ok(rest.overshoot > .1, `${fps}fps: no give at all`);
    assert.ok(rest.overshoot < 5, `${fps}fps: it wobbles`);
    assert.ok(rest.settledBy !== null && rest.settledBy < .8, `${fps}fps: it never settles`);
  }
});

test('every place is on one edge and back, round the whole border', () => {
  const run = page();
  for (const [edge, along] of [['top', 400], ['right', 300], ['bottom', 700], ['left', 900]]) {
    const [back, at] = run(`placeAt(positionOn('${edge}', ${along}))`);
    assert.equal(back, edge);
    assert.ok(Math.abs(at - along) < .001, `${edge} ${along} came back as ${at}`);
  }
  const perimeter = run('perimeter()');
  assert.ok(Math.abs(run('wrap(-10)') - (perimeter - 10)) < .001);
  assert.ok(Math.abs(run('signed(perimeter() - 10)') + 10) < .001, 'just behind the start is a step back');
});

test('it knows when it reaches round a corner', () => {
  const run = page();
  assert.equal(run('cornerFor(900, 200)'), null, 'in the middle of the top');
  const round = run('cornerFor(1800 - 40, 200)');
  assert.equal(round.corner, 'topRight');
  assert.ok(Math.abs(round.before - 140) < .001 && Math.abs(round.after - 60) < .001);
  const wrapped = run('cornerFor(30, 200)');
  assert.equal(wrapped.corner, 'topLeft', 'across the start of the line');
  assert.ok(Math.abs(wrapped.before + wrapped.after - 200) < .001 && Math.abs(wrapped.after - 130) < .001);
});

test('it comes to rest where its window can be put down', () => {
  const run = page();
  // The window is 650 long and kept in the work area, so the notch's middle stays 325 from an end
  assert.deepEqual(JSON.parse(run(`JSON.stringify(placeAt(resting(positionOn('right', 40))))`)), ['right', 325]);
  assert.deepEqual(JSON.parse(run(`JSON.stringify(placeAt(resting(positionOn('top', 1790))))`)), ['top', 1800 - 325]);
  assert.deepEqual(JSON.parse(run(`JSON.stringify(placeAt(resting(positionOn('left', 600))))`)), ['left', 600], 'clear of the ends it stays put');
});

test('the drawing is turned over on the left and bottom edges, so its flares still curve outward', () => {
  const run = page();
  const sweeps = (edge) => [...run(`notchPath('${edge}', 300, 500, 70, 20, 38.7)`).matchAll(/A[\d.]+ [\d.]+ 0 0 (\d)/g)].map((m) => m[1]).join('');
  assert.equal(sweeps('right'), '1001');
  assert.equal(sweeps('top'), '1001');
  assert.equal(sweeps('left'), '0110');
  assert.equal(sweeps('bottom'), '0110');
});

test('going round a corner it turns from one edge\'s size to the other\'s without a step', () => {
  const run = page();
  // Flat on the top the notch is 200 long, upright on the right 300: along the top it is the one,
  // all the way round the other, and never anything but in between
  let last = null;
  for (let p = 1800 - 150; p <= 1800 + 200; p += 2) {
    const { length, turned } = JSON.parse(run(`JSON.stringify(shapeAt(${p}, 0))`));
    assert.ok(length >= 200 - .001 && length <= 300 + .001, `at ${p} it is ${length} long`);
    assert.ok(turned >= 0 && turned <= 1);
    if (last !== null) assert.ok(Math.abs(length - last) < 6, `at ${p} it jumped from ${last} to ${length}`);
    last = length;
  }
});

test('the rings go round a corner on a curve, never a step', () => {
  const run = page();
  for (const [corner, inset] of [[1800, 34.5], [0, 47.5], [1800 + 1169, 40]]) {
    let last = null;
    for (let t = corner - 200; t <= corner + 200; t += 1) {
      const [x, y] = JSON.parse(run(`JSON.stringify(ringPoint(wrap(${t}), ${inset}))`));
      if (last) assert.ok(Math.hypot(x - last[0], y - last[1]) < 2, `stepped at ${t} near ${corner}`);
      last = [x, y];
    }
  }
});

test('let go round a corner, it flows off onto the edge more of it was on, and rests there', () => {
  const run = page();
  run(`passing = { corner: 'topRight', before: 150, after: 50 }; target = 1800; letGo();`);
  assert.deepEqual(JSON.parse(run('JSON.stringify(placeAt(target))')), ['top', 1800 - 325]);
  run(`passing = { corner: 'topRight', before: 40, after: 160 }; target = 1800; letGo();`);
  assert.deepEqual(JSON.parse(run('JSON.stringify(placeAt(target))')), ['right', 325]);
  assert.equal(run('settling'), true);
});

test('a part in the corner closes up square as the notch goes round, and not before', () => {
  const run = page();
  const arcs = (source) => [...run(source).matchAll(/A([\d.]+) [\d.]+ 0 0 \d/g)].map((m) => Number(m[1]));
  // Just arrived at the corner, its end there is still the notch's own: flare and corner
  assert.deepEqual(arcs(`piece('top', 'topRight', 200, true, 0, 0, 95)`), [38.7, 20, 20, 38.7]);
  // Gone round by its whole depth, that end is square
  assert.deepEqual(arcs(`piece('top', 'topRight', 200, true, 1, 95, 95)`), [38.7, 20, 0, 0]);
});

test('the notch and the drawing of it show the same settings end, frame for frame', () => {
  // They hand over at any moment of it, so a difference between the two copies is a jump on screen
  const notch = readFileSync(join(__dirname, 'codenotch/ui/notch.html'), 'utf8');
  const pick = (source, start, end) => {
    const a = source.indexOf(start);
    assert.ok(a >= 0, `missing ${start}`);
    return source.slice(a, source.indexOf(end, a) + end.length);
  };
  for (const [start, end] of [['const smooth=x=>', '};\n'], ['const clamp01=x=>', ';\n'], ['function handleFrame(c,now){', '\n}\n'],
    ['function quarter(', '\n}\n'], ['function strand(', '\n}\n'], ['function discMerge(', '\n}\n']]) {
    assert.equal(pick(html, start, end), pick(notch, start, end), start);
  }
});

test('held by its dots, they squeeze in the hand, spring back when let go, and go back out on landing', () => {
  const run = page();
  const at = (source) => JSON.parse(run(`JSON.stringify(${source})`));
  const taken = at('handleFrame({ at: 0, fromHover: true }, 600)');
  assert.ok(taken.merged > .99 && taken.held > .99 && taken.squeeze > .99, 'in the hand: the orb in, the dots in its place, squeezed');
  const letGo = at('handleFrame({ at: 0, fromHover: true, releasedAt: 1000 }, 1400)');
  assert.ok(letGo.squeeze < .01, 'let go, the squeeze is gone');
  const down = at('handleFrame({ at: 0, fromHover: true, releasedAt: 1000, landedAt: 1500 }, 2100)');
  assert.ok(down.merged < .01 && down.held < .01 && down.gear > .99, 'put down: the orb out again and the dots beside it');
  const alt = at('handleFrame({ at: 0, fromHover: false, landedAt: 1000 }, 1600)');
  assert.ok(alt.dots < .01 && alt.arc > .99, 'put down after Alt+drag: the dots gone and the arc back');
});

test('taken by its dots, the disc goes into the notch on a neck, from exactly where it was', () => {
  const run = page();
  const at = (t) => JSON.parse(run(`JSON.stringify(discMerge(${t}, 38.7, 6.8, 23.3, [Math.SQRT1_2, -Math.SQRT1_2]))`));
  const start = at(0);
  assert.deepEqual(start.disc.map(Math.abs), [0, 0, 23.3]);
  assert.equal(start.liquid, false, 'the first frame is the disc itself');
  assert.ok(at(.5).liquid && at(.5).neck, 'held on a neck on its way');
  const [x, y, r] = at(1).disc;
  assert.ok(Math.hypot(x, y) - r > 38.7 + .5, 'in the end wholly inside the notch, past where it is cut back');
});
