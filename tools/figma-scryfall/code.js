// Scryfall Fill: fills named layers in the selection with card data from Scryfall.
// A layer named "#name" gets the card name, "#art" gets the art crop as an image fill,
// "#color" gets a solid fill for the card's color, and so on (see README.md).
// Instances also match text component properties by name ("Name", "Mana cost", ...).
// Prefix a field with "back." (e.g. "#back.name") to read the back face of a double-faced card.

figma.showUI(__html__, { width: 360, height: 620, themeColors: true });

const ALIASES = {
  mana: 'mana_cost', cost: 'mana_cost', mv: 'cmc', mana_value: 'cmc',
  type: 'type_line', text: 'oracle_text', oracle: 'oracle_text', rules: 'oracle_text',
  flavor: 'flavor_text', number: 'collector_number', cn: 'collector_number',
  set_code: 'set', usd: 'price', eur: 'price_eur', art_crop: 'art', title: 'name',
};

// Layer name -> Scryfall image_uris size.
const IMAGE_FIELDS = { image: 'large', art: 'art_crop', image_normal: 'normal', image_png: 'png', image_small: 'small', border_crop: 'border_crop' };

const COLOR_HEX = { W: '#F8F6D8', U: '#0E68AB', B: '#150B00', R: '#D3202A', G: '#00733E' };
const MULTI_HEX = '#C9A94E';
const COLORLESS_HEX = '#9A9AA6';

// Fields with a dedicated getter. s = the face being read (merged over the card), card = the whole card.
const TEXT = {
  name: (s) => s.name,
  full_name: (s, card) => card.name,
  cmc: (s, card) => (card.cmc == null ? '' : String(card.cmc)),
  pt: (s) => (s.power != null ? s.power + '/' + s.toughness : s.loyalty || s.defense || ''),
  set: (s, card) => (card.set || '').toUpperCase(),
  colors: (s) => (s.colors || []).join(''),
  color_identity: (s, card) => (card.color_identity || []).join(''),
  keywords: (s, card) => (card.keywords || []).join(', '),
  price: (s, card) => money('$', card.prices && card.prices.usd),
  price_foil: (s, card) => money('$', card.prices && card.prices.usd_foil),
  price_eur: (s, card) => money('€', card.prices && card.prices.eur),
};

// Known fields: when a card has no value for one, its layer is emptied (and hidden if "Hide empty" is on).
const KNOWN = new Set(Object.keys(TEXT).concat([
  'mana_cost', 'type_line', 'oracle_text', 'flavor_text', 'power', 'toughness', 'loyalty', 'defense',
  'set_name', 'collector_number', 'rarity', 'artist', 'released_at', 'lang', 'id', 'scryfall_uri',
]));

function money(sign, v) {
  return v ? sign + v : '';
}

function parseField(raw) {
  let key = raw.trim().toLowerCase().replace(/[\s-]+/g, '_');
  let back = false;
  if (key.indexOf('back.') === 0) {
    back = true;
    key = key.slice(5);
  }
  return { key: ALIASES[key] || key, back };
}

function layerField(node) {
  const m = /^#([A-Za-z0-9_.-]+)/.exec(node.name.trim());
  return m ? parseField(m[1]) : null;
}

function fieldLabel(f) {
  return (f.back ? 'back.' : '') + f.key;
}

// The face a field reads from: the front face (or the card itself), or the back face for "back." fields.
function side(card, back) {
  const faces = card.card_faces;
  if (!faces) return back ? null : card;
  const face = faces[back ? 1 : 0];
  return face ? Object.assign({}, card, face) : null;
}

// Returns the text for a field, '' for a known field the card lacks, undefined for an unknown field.
function textValue(card, f) {
  const s = side(card, f.back);
  if (!s) return KNOWN.has(f.key) ? '' : undefined;
  const getter = TEXT[f.key];
  if (getter) {
    const v = getter(s, card);
    return v == null ? '' : String(v);
  }
  const v = s[f.key];
  if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (Array.isArray(v) && v.every((x) => typeof x === 'string')) return v.join(', ');
  return KNOWN.has(f.key) ? '' : undefined;
}

function imageUrl(card, f) {
  const s = side(card, f.back);
  if (!s) return null;
  // Split and flip cards keep one image on the card, not per face.
  const uris = s.image_uris || card.image_uris;
  return uris ? uris[IMAGE_FIELDS[f.key]] : null;
}

function colorHex(card, f) {
  const s = side(card, f.back) || card;
  let colors = s.colors && s.colors.length ? s.colors : card.color_identity || [];
  if (colors.length > 1) return MULTI_HEX;
  if (colors.length === 1) return COLOR_HEX[colors[0]] || COLORLESS_HEX;
  return COLORLESS_HEX;
}

function solid(hex) {
  const n = parseInt(hex.slice(1), 16);
  return { type: 'SOLID', color: { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 } };
}

const imageCache = new Map();
function imageHash(url) {
  if (!imageCache.has(url)) {
    const p = figma.createImageAsync(url).then((img) => img.hash);
    p.catch(() => imageCache.delete(url));
    imageCache.set(url, p);
  }
  return imageCache.get(url);
}

async function loadFontsOf(textNode) {
  const len = textNode.characters.length;
  const fonts = len ? textNode.getRangeAllFontNames(0, len) : textNode.fontName === figma.mixed ? [] : [textNode.fontName];
  await Promise.all(fonts.map((f) => figma.loadFontAsync(f)));
}

async function setText(node, value) {
  if (node.characters === value) return;
  await loadFontsOf(node);
  node.characters = value;
}

function targetsIn(root) {
  const out = layerField(root) ? [root] : [];
  if ('findAll' in root) return out.concat(root.findAll((n) => !!layerField(n)));
  return out;
}

function instancesIn(root) {
  const out = root.type === 'INSTANCE' ? [root] : [];
  if ('findAllWithCriteria' in root) return out.concat(root.findAllWithCriteria({ types: ['INSTANCE'] }));
  return out;
}

// Text component properties whose name is a card field: [{ node, prop, field }].
function textPropsIn(root) {
  const out = [];
  for (const inst of instancesIn(root)) {
    let props;
    try {
      props = inst.componentProperties;
    } catch (e) {
      continue;
    }
    for (const prop of Object.keys(props)) {
      if (props[prop].type !== 'TEXT') continue;
      const f = parseField(prop.split('#')[0].replace(/^#/, ''));
      if (KNOWN.has(f.key)) out.push({ node: inst, prop, field: f });
    }
  }
  return out;
}

async function fillRoot(root, card, opts, report) {
  for (const node of targetsIn(root)) {
    const f = layerField(node);
    try {
      if (IMAGE_FIELDS[f.key]) {
        if (!('fills' in node)) continue;
        const url = imageUrl(card, f);
        if (!url) {
          if (opts.hideEmpty) node.visible = false;
          continue;
        }
        const hash = await imageHash(url);
        const old = Array.isArray(node.fills) ? node.fills.find((p) => p.type === 'IMAGE') : null;
        node.fills = [{ type: 'IMAGE', imageHash: hash, scaleMode: old ? old.scaleMode : 'FILL' }];
        node.visible = true;
        report.filled++;
      } else if (f.key === 'color') {
        if (!('fills' in node)) continue;
        node.fills = [solid(colorHex(card, f))];
        report.filled++;
      } else {
        const value = textValue(card, f);
        if (value === undefined) {
          report.unknown.add(fieldLabel(f));
          continue;
        }
        // A frame named "#pt" fills its first text layer and hides as a whole when empty.
        const text = node.type === 'TEXT' ? node : 'findOne' in node ? node.findOne((n) => n.type === 'TEXT') : null;
        if (opts.hideEmpty) node.visible = value !== '';
        if (text && value !== '') {
          await setText(text, value);
          report.filled++;
        } else if (text && !opts.hideEmpty) {
          await setText(text, '');
        }
      }
    } catch (e) {
      report.errors.push(node.name + ': ' + (e && e.message ? e.message : e));
    }
  }

  for (const { node, prop, field } of textPropsIn(root)) {
    try {
      for (const t of node.findAllWithCriteria({ types: ['TEXT'] })) await loadFontsOf(t);
      node.setProperties({ [prop]: textValue(card, field) || '' });
      report.filled++;
    } catch (e) {
      report.errors.push(node.name + ' / ' + prop.split('#')[0] + ': ' + (e && e.message ? e.message : e));
    }
  }

  try {
    root.setPluginData('scryfall_id', card.id);
    root.setRelaunchData({ swap: card.name });
  } catch (e) {
    // Not every node accepts relaunch data (e.g. nodes inside an instance); the fill still counts.
  }
}

// Reading order: top-to-bottom rows, then left-to-right.
function sortedSelection() {
  const nodes = figma.currentPage.selection.slice();
  const box = (n) => n.absoluteBoundingBox || { x: 0, y: 0, height: 0 };
  return nodes.sort((a, b) => {
    const A = box(a);
    const B = box(b);
    const sameRow = Math.abs(A.y - B.y) < Math.min(A.height, B.height) / 2;
    return sameRow ? A.x - B.x : A.y - B.y;
  });
}

async function apply(cards, mode, opts) {
  const roots = sortedSelection();
  if (!roots.length) {
    figma.notify('Select a frame, component or instance with #field layers first');
    return;
  }
  const report = { filled: 0, unknown: new Set(), errors: [] };
  const count = mode === 'each' ? Math.min(roots.length, cards.length) : roots.length;
  for (let i = 0; i < count; i++) {
    await fillRoot(roots[i], mode === 'each' ? cards[i] : cards[0], opts, report);
  }

  let msg =
    mode === 'each'
      ? 'Filled ' + count + ' of ' + roots.length + ' with ' + count + ' cards'
      : 'Filled ' + report.filled + ' layers with ' + cards[0].name;
  if (report.unknown.size) msg += ' · unknown: ' + Array.from(report.unknown).join(', ');
  if (report.errors.length) {
    msg += ' · ' + report.errors.length + ' failed (see console)';
    console.warn('Scryfall Fill', report.errors);
  }
  figma.notify(msg, { error: report.filled === 0 });
}

function postSelection() {
  const roots = figma.currentPage.selection;
  const fields = new Set();
  let count = 0;
  for (const r of roots) {
    for (const n of targetsIn(r)) {
      fields.add(fieldLabel(layerField(n)));
      count++;
    }
    for (const p of textPropsIn(r)) {
      fields.add(fieldLabel(p.field));
      count++;
    }
  }
  figma.ui.postMessage({ type: 'selection', roots: roots.length, count, fields: Array.from(fields) });
}

async function scaffold() {
  let family = 'JetBrains Mono';
  try {
    await Promise.all([figma.loadFontAsync({ family, style: 'Regular' }), figma.loadFontAsync({ family, style: 'Bold' })]);
  } catch (e) {
    family = 'Inter';
    await Promise.all([figma.loadFontAsync({ family, style: 'Regular' }), figma.loadFontAsync({ family, style: 'Bold' })]);
  }

  const text = (name, placeholder, size, hex, bold) => {
    const t = figma.createText();
    t.name = name;
    t.fontName = { family, style: bold ? 'Bold' : 'Regular' };
    t.fontSize = size;
    t.fills = [solid(hex)];
    t.characters = placeholder;
    return t;
  };
  const row = (name) => {
    const f = figma.createFrame();
    f.name = name;
    f.layoutMode = 'HORIZONTAL';
    f.primaryAxisAlignItems = 'SPACE_BETWEEN';
    f.counterAxisAlignItems = 'CENTER';
    f.counterAxisSizingMode = 'AUTO';
    f.itemSpacing = 8;
    f.fills = [];
    return f;
  };

  const W = 252;
  const card = figma.createComponent();
  card.name = 'Card / Scryfall';
  card.layoutMode = 'VERTICAL';
  card.primaryAxisSizingMode = 'AUTO';
  card.counterAxisSizingMode = 'FIXED';
  card.resize(W, 352);
  card.paddingTop = card.paddingBottom = card.paddingLeft = card.paddingRight = 12;
  card.itemSpacing = 8;
  card.fills = [solid('#171725')];

  const stripe = figma.createRectangle();
  stripe.name = '#color';
  stripe.resize(W - 24, 3);
  stripe.fills = [solid(COLORLESS_HEX)];
  card.appendChild(stripe);
  stripe.layoutSizingHorizontal = 'FILL';

  const header = row('Header');
  card.appendChild(header);
  header.layoutSizingHorizontal = 'FILL';
  const name = text('#name', 'Card name', 13, '#FFFFFF', true);
  header.appendChild(name);
  name.layoutSizingHorizontal = 'FILL';
  header.appendChild(text('#mana_cost', '{1}{R}', 11, '#9B9BAA', false));

  const art = figma.createRectangle();
  art.name = '#art';
  art.resize(W - 24, 168);
  art.fills = [solid('#282839')];
  card.appendChild(art);
  art.layoutSizingHorizontal = 'FILL';

  card.appendChild(text('#type_line', 'Type — Subtype', 11, '#FFFFFF', false));
  const oracle = text('#oracle_text', 'Rules text', 11, '#C8C8D2', false);
  card.appendChild(oracle);
  oracle.layoutSizingHorizontal = 'FILL';
  oracle.textAutoResize = 'HEIGHT';

  const footer = row('Footer');
  card.appendChild(footer);
  footer.layoutSizingHorizontal = 'FILL';
  footer.appendChild(text('#set', 'SET', 10, '#9B9BAA', false));
  footer.appendChild(text('#price', '$0.00', 10, '#00FFD9', false));
  footer.appendChild(text('#pt', '0/0', 12, '#FFFFFF', true));

  const c = figma.viewport.center;
  card.x = Math.round(c.x - W / 2);
  card.y = Math.round(c.y - card.height / 2);
  figma.currentPage.appendChild(card);
  figma.currentPage.selection = [card];
  figma.viewport.scrollAndZoomIntoView([card]);
}

figma.on('selectionchange', postSelection);
figma.on('currentpagechange', postSelection);

figma.ui.onmessage = async (msg) => {
  if (msg.type === 'apply') {
    figma.ui.postMessage({ type: 'busy', busy: true });
    try {
      await apply(msg.cards, msg.mode, { hideEmpty: !!msg.hideEmpty });
    } finally {
      figma.ui.postMessage({ type: 'busy', busy: false });
      postSelection();
    }
  } else if (msg.type === 'scaffold') {
    await scaffold();
  } else if (msg.type === 'settings') {
    await figma.clientStorage.setAsync('settings', msg.settings);
  } else if (msg.type === 'notify') {
    figma.notify(msg.text, { error: !!msg.error });
  }
};

(async () => {
  const settings = (await figma.clientStorage.getAsync('settings')) || {};
  figma.ui.postMessage({ type: 'settings', settings });
  postSelection();
})();
