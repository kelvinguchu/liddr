// Line icons drawn for the console on a 24px grid. Built as SVG nodes, never parsed from strings.

const NS = 'http://www.w3.org/2000/svg';

const ICONS = {
  documents: [['path', 'M7 3h7l5 5v13H7z'], ['path', 'M14 3v5h5'], ['path', 'M10 14l2 2 4-4']],
  flag: [['path', 'M5 21V4'], ['path', 'M5 4h12l-2.5 4L17 12H5']],
  scale: [['path', 'M12 4v16'], ['path', 'M8 20h8'], ['path', 'M5 7h14'], ['path', 'M5 7l-3 6a3 3 0 0 0 6 0z'], ['path', 'M19 7l-3 6a3 3 0 0 0 6 0z']],
  ban: [['circle', 12, 12, 9], ['path', 'M5.6 5.6l12.8 12.8']],
  cash: [['rect', 2.5, 6, 19, 12, 2], ['circle', 12, 12, 2.5], ['path', 'M6 9.5v5M18 9.5v5']],
  receipt: [['path', 'M6 3h12v18l-3-2-3 2-3-2-3 2z'], ['path', 'M9 8h6M9 12h6M9 16h3']],
  signout: [['path', 'M14 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4'], ['path', 'M9 8l-4 4 4 4'], ['path', 'M5 12h10']],
  refresh: [['path', 'M20 12a8 8 0 1 1-2.34-5.66'], ['path', 'M20 4v5h-5']],
  close: [['path', 'M6 6l12 12M18 6L6 18']],
  menu: [['path', 'M4 7h16M4 12h16M4 17h16']],
  shield: [['path', 'M12 3l7 3v6c0 4.4-3 7.6-7 9-4-1.4-7-4.6-7-9V6z'], ['path', 'M9 12l2 2 4-4']],
  plus: [['path', 'M12 5v14M5 12h14']],
  eye: [['path', 'M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z'], ['circle', 12, 12, 3]],
  search: [['circle', 11, 11, 6.5], ['path', 'M20 20l-4.2-4.2']],
  phone: [['rect', 7, 2.5, 10, 19, 2], ['path', 'M11 18h2']],
  key: [['circle', 8, 15, 4], ['path', 'M11 12l8-8M16 7l2 2M14 9l2 2']],
  check: [['path', 'M5 12.5l4.5 4.5L19 7.5']],
  alert: [['circle', 12, 12, 9], ['path', 'M12 7.5v5.5M12 16.5v.01']],
  external: [['path', 'M14 4h6v6'], ['path', 'M20 4l-9 9'], ['path', 'M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5']],
  arrowLeft: [['path', 'M19 12H5M11 6l-6 6 6 6']],
  more: [['circle', 5.5, 12, 1.2], ['circle', 12, 12, 1.2], ['circle', 18.5, 12, 1.2]],
  sliders: [['path', 'M4 7h9M17 7h3M4 17h3M11 17h9'], ['circle', 15, 7, 2], ['circle', 9, 17, 2]],
  chevronDown: [['path', 'M6 9l6 6 6-6']],
};

/** Returns an icon element; decorative unless a label is given. */
export function icon(name, { size = 18, label } = {}) {
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.6');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('class', 'icon');
  if (label) {
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', label);
  } else {
    svg.setAttribute('aria-hidden', 'true');
  }
  for (const [kind, ...args] of ICONS[name] || []) {
    const el = document.createElementNS(NS, kind);
    if (kind === 'path') el.setAttribute('d', args[0]);
    if (kind === 'circle') ['cx', 'cy', 'r'].forEach((k, i) => el.setAttribute(k, String(args[i])));
    if (kind === 'rect') ['x', 'y', 'width', 'height', 'rx'].forEach((k, i) => el.setAttribute(k, String(args[i])));
    svg.append(el);
  }
  return svg;
}
