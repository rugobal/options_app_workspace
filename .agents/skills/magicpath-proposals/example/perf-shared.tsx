import {
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from 'react';
import './perf-shared.css';

/* ------------------------------------------------------------------ types */

export type Grouping = 'daily' | 'weekly' | 'monthly';
export type PresetKey = 'today' | 'week' | 'month' | 'last30' | 'ytd';
export type PreviewState = 'data' | 'loading' | 'error' | 'empty' | 'single' | 'zero';
export type Currency = 'USD' | 'EUR';
export type Caveat = 'missing_commission' | 'estimated_settlement';
export type ActiveSource = 'chart' | 'table';

export interface Trade {
  id: number;
  day: string; // local completion date, YYYY-MM-DD
  template: string;
  symbol: string;
  currency: Currency;
  gross: number; // cents
  commission: number; // cents
  net: number; // cents, gross - commission (deducted once)
  caveats: Caveat[];
}

export interface Period {
  key: string;
  label: string; // table / readout label
  tick: string; // axis label
  start: string;
  end: string;
  partial: boolean;
  count: number;
  gross: number;
  commission: number;
  net: number;
  cumulative: number;
  missingFees: number;
  estimated: number;
  provisional: number;
}

/* ------------------------------------------------------------------ dates */

export const TODAY = '2026-10-07';
const DAY_MS = 86400000;
export const parseDay = (s: string) => {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d));
};
export const fmtDay = (d: Date) => d.toISOString().slice(0, 10);
export const addDays = (d: Date, n: number) => new Date(d.getTime() + n * DAY_MS);
const utcFormat = (opts: Intl.DateTimeFormatOptions) =>
  new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', ...opts });
const F_WEEKDAY = utcFormat({ weekday: 'short', month: 'short', day: 'numeric' });
const F_MONTH_DAY = utcFormat({ month: 'short', day: 'numeric' });
const F_MONTH = utcFormat({ month: 'short' });
const F_MONTH_YEAR = utcFormat({ month: 'long', year: 'numeric' });
const F_LONG_MONTH = utcFormat({ month: 'long' });

export const shortDate = (s: string) => F_MONTH_DAY.format(parseDay(s));
export function ordinalDate(s: string) {
  const d = parseDay(s);
  const n = d.getUTCDate();
  const suffix =
    n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th';
  return `${F_LONG_MONTH.format(d)} ${n}${suffix} ${d.getUTCFullYear()}`;
}

export const PRESETS: { key: PresetKey; label: string }[] = [
  { key: 'today', label: 'Today' },
  { key: 'week', label: 'This week' },
  { key: 'month', label: 'This month' },
  { key: 'last30', label: 'Last 30 days' },
  { key: 'ytd', label: 'Year to date' },
];

export function presetRange(key: PresetKey): { from: string; to: string } {
  const t = parseDay(TODAY);
  switch (key) {
    case 'today':
      return { from: TODAY, to: TODAY };
    case 'week':
      return { from: fmtDay(addDays(t, -((t.getUTCDay() + 6) % 7))), to: TODAY };
    case 'month':
      return { from: '2026-10-01', to: TODAY };
    case 'last30':
      return { from: fmtDay(addDays(t, -29)), to: TODAY };
    case 'ytd':
      return { from: '2026-01-01', to: TODAY };
  }
}

export const unitOf = (g: Grouping) => (g === 'daily' ? 'day' : g === 'weekly' ? 'week' : 'month');

/* ------------------------------------------------------------------ money */

const SYMBOL: Record<Currency, string> = { USD: '$', EUR: '€' };

export function money(cents: number, currency: Currency) {
  const abs = (Math.abs(cents) / 100).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return `${cents < 0 ? '-' : ''}${SYMBOL[currency]}${abs}`;
}

export function axisMoney(cents: number, currency: Currency) {
  const v = cents / 100;
  const abs = Math.abs(v);
  const text =
    abs >= 1000
      ? `${(abs / 1000).toLocaleString('en-US', { maximumFractionDigits: 1 })}k`
      : abs.toLocaleString('en-US', { maximumFractionDigits: 0 });
  return `${v < 0 ? '-' : ''}${SYMBOL[currency]}${text}`;
}

export const signClass = (cents: number) => (cents > 0 ? 'pf-pos' : cents < 0 ? 'pf-neg' : '');

export function niceScale(min: number, max: number, count = 4) {
  let lo0 = Math.min(min, 0);
  let hi0 = Math.max(max, 0);
  if (lo0 === hi0) {
    // zero-only data still gets a readable, symmetric axis around $0
    lo0 = -10000;
    hi0 = 10000;
  }
  const raw = (hi0 - lo0) / count;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const norm = raw / mag;
  const step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
  const lo = Math.floor(lo0 / step) * step;
  const hi = Math.ceil(hi0 / step) * step;
  const ticks: number[] = [];
  for (let v = lo; v <= hi + step / 2; v += step) ticks.push(Math.round(v));
  return { lo, hi, ticks };
}

/* ------------------------------------------------------------------ mock data */

function mulberry32(seed: number) {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const TEMPLATES = [
  { name: 'Iron Condor 0DTE', symbol: 'SPX', legs: 4 },
  { name: 'Vertical Put', symbol: 'SPX', legs: 2 },
  { name: 'Vertical Call 1,5x', symbol: 'SPY', legs: 2 },
  { name: 'MEIC', symbol: 'SPX', legs: 4 },
];

function generateTrades(): Trade[] {
  const rnd = mulberry32(20261007);
  const out: Trade[] = [];
  let id = 4100;
  for (let d = parseDay('2026-01-02'); fmtDay(d) <= TODAY; d = addDays(d, 1)) {
    const dow = d.getUTCDay();
    if (dow === 0 || dow === 6) continue;
    const day = fmtDay(d);
    const n = rnd() < 0.14 ? 0 : 1 + Math.floor(rnd() * 4);
    for (let i = 0; i < n; i++) {
      const t = TEMPLATES[Math.floor(rnd() * TEMPLATES.length)];
      const win = rnd() < 0.7;
      const gross = win ? Math.round((40 + rnd() * 200) * 100) : -Math.round((60 + rnd() * 380) * 100);
      let commission = Math.round(t.legs * (rnd() < 0.45 ? 1 : 2) * (1.05 + rnd() * 0.5) * 100);
      const caveats: Caveat[] = [];
      if (day >= '2026-10-05' && rnd() < 0.45) {
        caveats.push('missing_commission');
        commission = Math.round(commission / 2);
      }
      if (rnd() < 0.012) caveats.push('estimated_settlement');
      out.push({ id: id++, day, template: t.name, symbol: t.symbol, currency: 'USD', gross, commission, net: gross - commission, caveats });
    }
    if (day >= '2026-06-01' && (dow === 2 || dow === 4) && rnd() < 0.55) {
      const gross = rnd() < 0.66 ? Math.round((30 + rnd() * 140) * 100) : -Math.round((50 + rnd() * 260) * 100);
      const commission = Math.round((3 + rnd() * 2) * 100);
      out.push({ id: id++, day, template: 'Vertical Put EU', symbol: 'ESTX50', currency: 'EUR', gross, commission, net: gross - commission, caveats: [] });
    }
  }
  return out;
}

const ALL_TRADES = generateTrades();
const SINGLE_TRADE: Trade[] = [
  { id: 5001, day: '2026-10-02', template: 'Iron Condor 0DTE', symbol: 'SPX', currency: 'USD', gross: 18500, commission: 1056, net: 17444, caveats: [] },
];
const ZERO_TRADES: Trade[] = [
  { id: 5101, day: '2026-09-22', template: 'Vertical Put', symbol: 'SPX', currency: 'USD', gross: 528, commission: 528, net: 0, caveats: [] },
  { id: 5102, day: '2026-09-29', template: 'MEIC', symbol: 'SPX', currency: 'USD', gross: 1056, commission: 1056, net: 0, caveats: [] },
  { id: 5103, day: '2026-10-06', template: 'Vertical Put', symbol: 'SPX', currency: 'USD', gross: 528, commission: 528, net: 0, caveats: [] },
];

/* ------------------------------------------------------------------ aggregation */

export function buildPeriods(trades: Trade[], from: string, to: string, g: Grouping): Period[] {
  const byDay = new Map<string, Trade[]>();
  for (const t of trades) {
    const list = byDay.get(t.day);
    if (list) list.push(t);
    else byDay.set(t.day, [t]);
  }
  const start = parseDay(from);
  const end = parseDay(to);
  const out: Period[] = [];
  let cursor = start;
  let cumulative = 0;
  while (cursor <= end) {
    let ns: Date;
    let ne: Date;
    if (g === 'daily') {
      ns = cursor;
      ne = cursor;
    } else if (g === 'weekly') {
      ns = addDays(cursor, -((cursor.getUTCDay() + 6) % 7)); // weeks start Monday
      ne = addDays(ns, 6);
    } else {
      ns = new Date(Date.UTC(cursor.getUTCFullYear(), cursor.getUTCMonth(), 1));
      ne = new Date(Date.UTC(cursor.getUTCFullYear(), cursor.getUTCMonth() + 1, 0));
    }
    const s = ns < start ? start : ns;
    const e = ne > end ? end : ne;
    const partial = g !== 'daily' && (s.getTime() !== ns.getTime() || e.getTime() !== ne.getTime());
    const list: Trade[] = [];
    for (let d = s; d <= e; d = addDays(d, 1)) list.push(...(byDay.get(fmtDay(d)) ?? []));
    const gross = list.reduce((a, t) => a + t.gross, 0);
    const commission = list.reduce((a, t) => a + t.commission, 0);
    const net = list.reduce((a, t) => a + t.net, 0);
    cumulative += net;
    const sameDay = s.getTime() === e.getTime();
    const range = sameDay
      ? F_MONTH_DAY.format(s)
      : `${F_MONTH_DAY.format(s)}–${s.getUTCMonth() === e.getUTCMonth() ? e.getUTCDate() : F_MONTH_DAY.format(e)}`;
    const label = g === 'daily' ? F_WEEKDAY.format(s) : g === 'monthly' && !partial ? F_MONTH_YEAR.format(s) : range;
    const tick = g === 'monthly' ? F_MONTH.format(s) : F_MONTH_DAY.format(s);
    out.push({
      key: fmtDay(s),
      label,
      tick,
      start: fmtDay(s),
      end: fmtDay(e),
      partial,
      count: list.length,
      gross,
      commission,
      net,
      cumulative,
      missingFees: list.filter((t) => t.caveats.includes('missing_commission')).length,
      estimated: list.filter((t) => t.caveats.includes('estimated_settlement')).length,
      provisional: list.filter((t) => t.caveats.length > 0).length,
    });
    cursor = addDays(e, 1);
  }
  return out;
}

export function caveatText(p: { missingFees: number; estimated: number }) {
  const parts: string[] = [];
  if (p.missingFees) parts.push(`${p.missingFees} fee${p.missingFees > 1 ? 's' : ''} pending`);
  if (p.estimated) parts.push(`${p.estimated} estimated close`);
  return parts.join(' · ');
}

/* ------------------------------------------------------------------ model */

/** Longest range still readable as daily / weekly bars; longer ranges step up a grouping until the user picks one. */
const AUTO_DAILY_MAX_DAYS = 62;
const AUTO_WEEKLY_MAX_DAYS = 430;

export function usePerformanceModel() {
  const [preset, setPreset] = useState<PresetKey | null>('last30');
  const [range, setRange] = useState(presetRange('last30'));
  const [groupingChoice, setGroupingChoice] = useState<Grouping | null>(null);
  const rangeDays = Math.round((parseDay(range.to).getTime() - parseDay(range.from).getTime()) / DAY_MS) + 1;
  const autoGrouping: Grouping = rangeDays <= AUTO_DAILY_MAX_DAYS ? 'daily' : rangeDays <= AUTO_WEEKLY_MAX_DAYS ? 'weekly' : 'monthly';
  const grouping = groupingChoice ?? autoGrouping;
  const groupingIsAuto = groupingChoice == null && autoGrouping !== 'daily';
  const [currency, setCurrency] = useState<Currency>('USD');
  const [preview, setPreview] = useState<PreviewState>('data');
  const [templates, setTemplates] = useState<string[]>([]);
  const [symbols, setSymbols] = useState<string[]>([]);
  const [requesting, setRequesting] = useState(true);
  const [retryNo, setRetryNo] = useState(0);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [hover, setHover] = useState<number | null>(null);
  const [pinned, setPinned] = useState<number | null>(null);
  const [activeSource, setActiveSource] = useState<ActiveSource>('chart');

  // Dates, filters and retry issue a new request; grouping and currency redraw the loaded response.
  useEffect(() => {
    setRequesting(true);
    setDrawerOpen(false);
    const timer = window.setTimeout(() => setRequesting(false), 450);
    return () => window.clearTimeout(timer);
  }, [range.from, range.to, templates, symbols, retryNo]);

  const source = preview === 'single' ? SINGLE_TRADE : preview === 'zero' ? ZERO_TRADES : preview === 'empty' ? [] : ALL_TRADES;
  const inRange = useMemo(() => source.filter((t) => t.day >= range.from && t.day <= range.to), [source, range]);
  const templateOptions = useMemo(() => Array.from(new Set(inRange.map((t) => t.template))).sort(), [inRange]);
  const symbolOptions = useMemo(() => Array.from(new Set(inRange.map((t) => t.symbol))).sort(), [inRange]);
  const currencyOptions = useMemo(() => Array.from(new Set(inRange.map((t) => t.currency))).sort() as Currency[], [inRange]);
  const trades = useMemo(
    () =>
      inRange.filter(
        (t) =>
          t.currency === currency &&
          (templates.length === 0 || templates.includes(t.template)) &&
          (symbols.length === 0 || symbols.includes(t.symbol)),
      ),
    [inRange, currency, templates, symbols],
  );
  const periods = useMemo(() => buildPeriods(trades, range.from, range.to, grouping), [trades, range, grouping]);
  const totals = useMemo(() => {
    const gross = trades.reduce((a, t) => a + t.gross, 0);
    const commission = trades.reduce((a, t) => a + t.commission, 0);
    const net = trades.reduce((a, t) => a + t.net, 0);
    const missingFees = trades.filter((t) => t.caveats.includes('missing_commission')).length;
    const estimated = trades.filter((t) => t.caveats.includes('estimated_settlement')).length;
    return {
      count: trades.length,
      gross,
      commission,
      net,
      average: trades.length ? Math.round(net / trades.length) : null,
      missingFees,
      estimated,
      provisional: trades.filter((t) => t.caveats.length > 0).length,
    };
  }, [trades]);

  useEffect(() => {
    setHover(null);
    setPinned(null);
  }, [grouping, range, currency, preview, templates, symbols]);

  const status: 'loading' | 'error' | 'empty' | 'ready' =
    preview === 'loading' || requesting ? 'loading' : preview === 'error' ? 'error' : trades.length === 0 ? 'empty' : 'ready';

  let fallback = periods.length - 1;
  for (let i = periods.length - 1; i >= 0; i--) {
    if (periods[i].count > 0) {
      fallback = i;
      break;
    }
  }
  const clamp = (i: number) => Math.max(0, Math.min(periods.length - 1, i));
  const active = periods.length ? clamp(hover ?? pinned ?? fallback) : null;

  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

  return {
    preset,
    range,
    grouping,
    groupingIsAuto,
    currency,
    preview,
    templates,
    symbols,
    templateOptions,
    symbolOptions,
    currencyOptions,
    trades,
    periods,
    totals,
    status,
    drawerOpen,
    active,
    activeSource,
    timeZone,
    unit: unitOf(grouping),
    selectPreset(key: PresetKey) {
      setPreset(key);
      setRange(presetRange(key));
      setTemplates([]);
      setSymbols([]);
    },
    setGrouping: setGroupingChoice,
    setCurrency,
    setPreview(p: PreviewState) {
      setPreview(p);
      setRetryNo((n) => n + 1);
    },
    toggleTemplate(v: string) {
      setTemplates((cur) => (cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v]));
    },
    toggleSymbol(v: string) {
      setSymbols((cur) => (cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v]));
    },
    clearFilters() {
      setTemplates([]);
      setSymbols([]);
    },
    retry() {
      setPreview('data');
      setRetryNo((n) => n + 1);
    },
    setDrawerOpen,
    hoverAt(i: number | null, src: ActiveSource) {
      setHover(i);
      if (i != null) setActiveSource(src);
    },
    pin(i: number, src: ActiveSource) {
      setHover(null);
      setPinned(clamp(i));
      setActiveSource(src);
    },
    step(delta: number | 'home' | 'end', src: ActiveSource) {
      const cur = pinned ?? hover ?? fallback;
      const next = delta === 'home' ? 0 : delta === 'end' ? periods.length - 1 : cur + delta;
      setHover(null);
      setPinned(clamp(next));
      setActiveSource(src);
    },
  };
}

export type Model = ReturnType<typeof usePerformanceModel>;

/* ------------------------------------------------------------------ icons */

const ICONS: Record<string, string> = {
  menu: 'M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z',
  home: 'M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z',
  edit: 'M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1 1 0 0 0 0-1.41l-2.34-2.34a1 1 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z',
  schedule:
    'M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z',
  chart: 'M5 9.2h3V19H5zM10.6 5h2.8v14h-2.8zm5.6 8H19v6h-2.8z',
  bell: 'M12 22c1.1 0 2-.9 2-2h-4c0 1.1.89 2 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z',
  filter: 'M10 18h4v-2h-4v2zM3 6v2h18V6H3zm3 7h12v-2H6v2z',
  expand: 'M16.59 8.59 12 13.17 7.41 8.59 6 10l6 6 6-6z',
  drop: 'M7 10l5 5 5-5z',
  close: 'M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
  check: 'M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z',
};

export function Icon({ name, size = 22 }: { name: keyof typeof ICONS | string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" focusable="false" className="pf-icon">
      <path d={ICONS[name]} fill="currentColor" />
    </svg>
  );
}

/* ------------------------------------------------------------------ app shell */

const PREVIEWS: { key: PreviewState; label: string }[] = [
  { key: 'data', label: 'Data' },
  { key: 'loading', label: 'Loading' },
  { key: 'error', label: 'Error' },
  { key: 'empty', label: 'No trades' },
  { key: 'single', label: 'One trade' },
  { key: 'zero', label: 'All $0' },
];

export function AppShell({ model, children }: { model: Model; children: ReactNode }) {
  const nav: [string, string][] = [
    ['home', 'Home'],
    ['edit', 'Templates'],
    ['schedule', 'Schedules'],
    ['chart', 'Reports'],
  ];
  return (
    <div className="pf-app">
      <nav className="pf-sidebar" aria-label="Main">
        <button type="button" className="pf-side-menu" aria-label="Menu">
          <Icon name="menu" />
        </button>
        {nav.map(([icon, label]) => (
          <a
            key={label}
            href="#"
            className={`pf-side-link${label === 'Reports' ? ' is-active' : ''}`}
            aria-label={label}
            aria-current={label === 'Reports' ? 'page' : undefined}
            onClick={(e) => e.preventDefault()}
          >
            <Icon name={icon} />
          </a>
        ))}
      </nav>
      <div className="pf-main">
        <header className="pf-topbar">
          <span className="pf-wordmark">
            <span className="pf-wordmark-s">S</span>impleOptionSpreads
          </span>
          <div className="pf-preview" role="group" aria-label="Design preview state">
            <span>Design preview</span>
            {PREVIEWS.map((p) => (
              <button key={p.key} type="button" aria-pressed={model.preview === p.key} onClick={() => model.setPreview(p.key)}>
                {p.label}
              </button>
            ))}
          </div>
          <div className="pf-top-actions">
            <button type="button" aria-label="Notifications">
              <Icon name="bell" />
            </button>
            <span className="pf-avatar" aria-hidden="true">
              RG
            </span>
          </div>
        </header>
        <div className="pf-tabs" role="tablist" aria-label="Reports">
          {['Trades', 'Performance', 'Premium', 'Slippage'].map((t) => (
            <button key={t} type="button" role="tab" aria-selected={t === 'Performance'} tabIndex={t === 'Performance' ? 0 : -1} className="pf-tab">
              {t}
            </button>
          ))}
        </div>
        <div className="pf-column">
          <Toolbar model={model} />
          {children}
        </div>
      </div>
    </div>
  );
}

function Toolbar({ model }: { model: Model }) {
  const [open, setOpen] = useState(false);
  const panelRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const selected = model.templates.length + model.symbols.length;

  useEffect(() => {
    if (!open) return;
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpen(false);
        buttonRef.current?.focus();
      }
    };
    const onDown = (e: MouseEvent) => {
      const t = e.target as Node;
      if (!panelRef.current?.contains(t) && !buttonRef.current?.contains(t)) setOpen(false);
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('mousedown', onDown);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('mousedown', onDown);
    };
  }, [open]);

  return (
    <div className="pf-toolbar-card">
      <div className="pf-toolbar">
        <div className="pf-dates">
          <span className="pf-date-caption" aria-hidden="true">
            From
          </span>
          <span className="pf-date" aria-label="Start date">
            {ordinalDate(model.range.from)}
          </span>
          <span className="pf-date-caption" aria-hidden="true">
            To
          </span>
          <span className="pf-date" aria-label="End date">
            {ordinalDate(model.range.to)}
          </span>
        </div>
        <div className="pf-presets" role="group" aria-label="Date range">
          {PRESETS.map((p) => (
            <button key={p.key} type="button" className="pf-preset" aria-pressed={model.preset === p.key} onClick={() => model.selectPreset(p.key)}>
              {p.label}
            </button>
          ))}
        </div>
        <button
          ref={buttonRef}
          type="button"
          className="pf-filters-button"
          aria-expanded={open}
          aria-controls="pf-filters"
          aria-label={selected ? `Filters, ${selected} selected` : 'Filters'}
          onClick={() => setOpen((o) => !o)}
        >
          <Icon name="filter" size={18} />
          <span>Filters</span>
          {selected > 0 && <span className="pf-filters-count">{selected}</span>}
          <Icon name="expand" size={18} />
        </button>
      </div>
      {open && (
        <div id="pf-filters" ref={panelRef} className="pf-filters" role="group" aria-label="Report filters">
          <div className="pf-filters-head">
            <span>Filters</span>
            <button type="button" disabled={!selected} onClick={model.clearFilters}>
              Clear all
            </button>
          </div>
          <div className="pf-filters-grid">
            <ChipGroup label="Template" options={model.templateOptions} selected={model.templates} onToggle={model.toggleTemplate} />
            <ChipGroup label="Symbol" options={model.symbolOptions} selected={model.symbols} onToggle={model.toggleSymbol} />
          </div>
        </div>
      )}
    </div>
  );
}

function ChipGroup({ label, options, selected, onToggle }: { label: string; options: string[]; selected: string[]; onToggle: (v: string) => void }) {
  return (
    <div className="pf-filter-group">
      <span className="pf-filter-label">{label}</span>
      <div className="pf-chips" role="group" aria-label={`${label} filter`}>
        {options.length === 0 && <span className="pf-muted">None in this range</span>}
        {options.map((o) => {
          const on = selected.includes(o);
          return (
            <button key={o} type="button" role="checkbox" aria-checked={on} className="pf-chip" onClick={() => onToggle(o)}>
              {on && <Icon name="check" size={16} />}
              {o}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ report frame */

export function ReportFrame({
  model,
  children,
  summary,
  compactEvidence = false,
}: {
  model: Model;
  children: ReactNode;
  summary?: ReactNode;
  compactEvidence?: boolean;
}) {
  const m = model;
  const ready = m.status === 'ready';
  return (
    <section className="pf-report" aria-labelledby="pf-title" aria-busy={m.status === 'loading'}>
      <header className="pf-heading">
        <div>
          <h2 id="pf-title">Performance report</h2>
          <p className="pf-description">Net profit or loss from completed trades, after fees.</p>
        </div>
        <div className="pf-seg" role="group" aria-label="Group results by">
          {(['daily', 'weekly', 'monthly'] as Grouping[]).map((g) => (
            <button key={g} type="button" aria-pressed={m.grouping === g} onClick={() => m.setGrouping(g)}>
              {g === 'daily' ? 'Daily' : g === 'weekly' ? 'Weekly' : 'Monthly'}
            </button>
          ))}
        </div>
        <label className="pf-currency">
          <span>Currency</span>
          <span className="pf-select">
            <select value={m.currency} onChange={(e) => m.setCurrency(e.target.value as Currency)} disabled={m.status === 'loading' || m.status === 'error'}>
              {(['USD', 'EUR'] as Currency[]).map((c) => (
                <option key={c} value={c}>
                  {c}
                  {m.currencyOptions.includes(c) ? '' : ' (no results)'}
                </option>
              ))}
            </select>
            <Icon name="drop" size={20} />
          </span>
        </label>
      </header>
      <div className="pf-scope">
        <span>
          By completion date · {m.timeZone} · {m.currency}
          {ready && ` · ${m.totals.count} completed trade${m.totals.count === 1 ? '' : 's'} included`}
          {m.groupingIsAuto && <span className="pf-auto-note"> · {m.grouping === 'weekly' ? 'Weekly' : 'Monthly'}, because the range is long</span>}
        </span>
        <button type="button" className="pf-link" aria-expanded={m.drawerOpen} aria-controls="pf-drawer" onClick={() => m.setDrawerOpen(!m.drawerOpen)}>
          How the report works
        </button>
      </div>
      {summary ?? <MetricStrip model={m} />}
      {ready && (compactEvidence ? <CompactEvidenceNote model={m} /> : <EvidenceNote model={m} />)}
      <div className="pf-analysis-slot">{ready ? children : <StatusPanel model={m} />}</div>
      <p className="pf-footnote">
        Only completed trades are included. Trades with open positions are excluded, even if the app has stopped managing them. Failed or cancelled entry attempts are also excluded.
      </p>
      <MethodDrawer model={m} />
    </section>
  );
}

export function MetricStrip({ model, layout = 'strip' }: { model: Model; layout?: 'strip' | 'grid' }) {
  const m = model;
  const ready = m.status === 'ready';
  const t = m.totals;
  const feeBadge = ready && t.missingFees > 0 ? 'Fees may update' : ready && t.provisional > 0 ? 'May change' : null;
  const dash = '—';
  return (
    <dl className={layout === 'grid' ? 'pf-metrics-grid' : 'pf-metrics'} aria-label="Performance summary">
      <div>
        <dt>
          Net P&amp;L {feeBadge && <span className="pf-provisional">{feeBadge}</span>}
        </dt>
        <dd className={ready ? signClass(t.net) : ''}>{ready ? money(t.net, m.currency) : dash}</dd>
        <span>Completed trades, after commission</span>
      </div>
      <div>
        <dt>
          Commission {ready && t.missingFees > 0 && <span className="pf-provisional">Fees may update</span>}
        </dt>
        <dd>{ready ? money(t.commission, m.currency) : dash}</dd>
        <span>Commission fees reported by the broker</span>
      </div>
      <div>
        <dt>Completed trades</dt>
        <dd>{ready ? t.count : dash}</dd>
        <span>Trades included in these results</span>
      </div>
      <div>
        <dt>Average net P&amp;L</dt>
        <dd className={ready && t.average != null ? signClass(t.average) : ''}>{ready && t.average != null ? money(t.average, m.currency) : dash}</dd>
        <span>Net P&amp;L ÷ completed trades</span>
      </div>
    </dl>
  );
}

function EvidenceNote({ model }: { model: Model }) {
  const t = model.totals;
  if (!t.provisional) return null;
  const parts: string[] = [];
  if (t.missingFees)
    parts.push(
      `The broker may report commissions after execution. ${t.missingFees} trade${t.missingFees > 1 ? 's' : ''} stay included with fees received so far; later fees appear on the next report load. P&L changes only by those fees.`,
    );
  if (t.estimated) parts.push(`${t.estimated} result${t.estimated > 1 ? 's use' : ' uses'} an estimated closing price and ${t.estimated > 1 ? 'are' : 'is'} not final.`);
  return (
    <p className="pf-evidence" role="note">
      {parts.join(' ')}
    </p>
  );
}

/** One line in place of the full evidence paragraph; the explanation lives in the method drawer. */
function CompactEvidenceNote({ model }: { model: Model }) {
  const t = model.totals;
  if (!t.provisional) return null;
  const parts: string[] = [];
  if (t.missingFees) parts.push(`${t.missingFees} trade${t.missingFees > 1 ? 's’' : '’s'} fees may still update`);
  if (t.estimated) parts.push(`${t.estimated} estimated closing price${t.estimated > 1 ? 's' : ''}`);
  return (
    <p className="pf-evidence pf-evidence-compact" role="note">
      <span className="pf-evidence-text">{parts.join(' · ')}</span>
      <button type="button" className="pf-link pf-link-small" aria-controls="pf-drawer" onClick={() => model.setDrawerOpen(true)}>
        Why?
      </button>
    </p>
  );
}

function StatusPanel({ model }: { model: Model }) {
  const m = model;
  if (m.status === 'loading') {
    return (
      <div className="pf-panel pf-status pf-loading" role="status">
        <span className="pf-status-text">Loading completed trade results…</span>
        <div className="pf-skeleton" aria-hidden="true">
          {Array.from({ length: 18 }, (_, i) => (
            <span key={i} style={{ height: `${22 + ((i * 37) % 60)}%` }} />
          ))}
        </div>
      </div>
    );
  }
  if (m.status === 'error') {
    return (
      <div className="pf-panel pf-status" role="alert">
        <div>
          <p className="pf-status-text">Could not load the performance report.</p>
          <p className="pf-status-sub">Check the connection to the backend, then try again. Your dates and filters are kept.</p>
        </div>
        <button type="button" className="pf-link" onClick={m.retry}>
          Retry report
        </button>
      </div>
    );
  }
  const other = m.currencyOptions.filter((c) => c !== m.currency);
  return (
    <div className="pf-panel pf-status" role="status">
      <div>
        <p className="pf-status-text">
          No completed {m.currency} trades from {shortDate(m.range.from)} to {shortDate(m.range.to)}, {m.range.to.slice(0, 4)}.
        </p>
        <p className="pf-status-sub">
          {other.length > 0
            ? `There are completed ${other.join(', ')} trades in this range. Switch the currency to see them.`
            : 'Trades still open, including ones the app no longer manages, appear here once they complete.'}
        </p>
      </div>
      {other.length > 0 && (
        <button type="button" className="pf-link" onClick={() => m.setCurrency(other[0])}>
          Show {other[0]}
        </button>
      )}
    </div>
  );
}

function MethodDrawer({ model }: { model: Model }) {
  const m = model;
  const closeRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!m.drawerOpen) return;
    closeRef.current?.focus();
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') m.setDrawerOpen(false);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [m.drawerOpen]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!m.drawerOpen) return null;
  return (
    <aside id="pf-drawer" className="pf-drawer" role="dialog" aria-modal="false" aria-labelledby="pf-drawer-title">
      <div className="pf-drawer-head">
        <h3 id="pf-drawer-title">How the report works</h3>
        <button ref={closeRef} type="button" className="pf-icon-button" aria-label="Close report explanation" onClick={() => m.setDrawerOpen(false)}>
          <Icon name="close" size={20} />
        </button>
      </div>
      <div className="pf-drawer-body">
        <h4>How the report calculates your results</h4>
        <p>
          The date range uses each trade's completion date in your desktop's time zone ({m.timeZone}). A trade's whole result counts once, on the day it completed, even if some
          of its positions closed earlier.
        </p>
        <p>
          Net P&amp;L is gross profit or loss minus the commission the broker reported, deducted once. Amounts are rounded to cents. Average net P&amp;L is total net P&amp;L
          divided by the number of completed trades.
        </p>
        <p>
          The broker may report commissions after execution. Trades waiting for a commission report stay included with the fees received so far; later fees appear on the
          next report load. This is normal: P&amp;L changes only by those fees, but results near break-even can shift. Results that use an estimated closing price are not
          final.
        </p>
        <p>
          Days run from local midnight to midnight. Weeks start on Monday and months on the 1st. When the selected dates cut a week or month short, that period is marked
          partial and covers only the selected days. Ranges longer than about two months group by week, and ranges longer than about fourteen months by month, until
          you choose a grouping yourself.
        </p>
        <p>
          The running total starts at {money(0, m.currency)} on the first selected day. Days without completed trades keep it flat. It adds up completed-trade results; it is
          not your account balance.
        </p>
        <p>
          Trades with open positions (including ones the app no longer manages), failed or cancelled entries, and trades whose results cannot be checked are not included.
          Each currency is shown separately; no conversion is applied.
        </p>
      </div>
    </aside>
  );
}

/* ------------------------------------------------------------------ chart primitives */

export function useElementSize<T extends HTMLElement>() {
  const [el, setEl] = useState<T | null>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => {
      const r = entry.contentRect;
      setSize({ w: Math.floor(r.width), h: Math.floor(r.height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [el]);
  return [setEl, size] as const;
}

export const PAD = { l: 70, r: 18 };

export function bandGeometry(n: number, width: number) {
  const inner = Math.max(width - PAD.l - PAD.r, 10);
  const band = inner / Math.max(n, 1);
  return { band, x0: PAD.l, x1: PAD.l + inner, cx: (i: number) => PAD.l + band * (i + 0.5) };
}

interface ChartProps {
  model: Model;
  width: number;
  height: number;
  showXAxis?: boolean;
  tickCount?: number;
}

function XAxis({ model, width, y }: { model: Model; width: number; y: number }) {
  const g = bandGeometry(model.periods.length, width);
  const every = Math.max(1, Math.ceil((model.grouping === 'monthly' ? 44 : 56) / g.band));
  const n = model.periods.length;
  return (
    <g>
      {model.periods.map((p, i) =>
        (n - 1 - i) % every === 0 ? (
          <text key={p.key} x={g.cx(i)} y={y} className={`pf-xtick${i === model.active ? ' is-active' : ''}`} textAnchor="middle">
            {p.tick}
          </text>
        ) : null,
      )}
    </g>
  );
}

function HitLayer({ model, width, top, bottom }: { model: Model; width: number; top: number; bottom: number }) {
  const g = bandGeometry(model.periods.length, width);
  return (
    <g>
      {model.periods.map((p, i) => (
        <rect
          key={p.key}
          x={g.cx(i) - g.band / 2}
          y={top}
          width={g.band}
          height={Math.max(bottom - top, 1)}
          fill="transparent"
          onMouseEnter={() => model.hoverAt(i, 'chart')}
          onClick={() => model.pin(i, 'chart')}
        />
      ))}
    </g>
  );
}

export function PeriodBarsChart({ model, width, height, showXAxis = true, tickCount }: ChartProps) {
  if (width < 60 || height < 50) return null;
  const top = 10;
  const bottom = height - (showXAxis ? 24 : 6);
  const nets = model.periods.filter((p) => p.count > 0).map((p) => p.net);
  const { lo, hi, ticks } = niceScale(Math.min(0, ...nets), Math.max(0, ...nets), tickCount ?? (height < 150 ? 2 : 4));
  const y = (v: number) => top + ((hi - v) / (hi - lo)) * (bottom - top);
  const g = bandGeometry(model.periods.length, width);
  const bw = Math.max(2, Math.min(g.band * 0.62, 34));
  const a = model.active;
  return (
    <svg width={width} height={height} className="pf-svg" aria-hidden="true">
      {a != null && <rect x={g.cx(a) - g.band / 2} y={top} width={g.band} height={bottom - top} className="pf-active-band" />}
      {ticks.map((t) => (
        <g key={t}>
          <line x1={g.x0} x2={g.x1} y1={y(t)} y2={y(t)} className={t === 0 ? 'pf-zero' : 'pf-grid'} />
          <text x={g.x0 - 10} y={y(t)} dy="0.32em" textAnchor="end" className={`pf-ytick${t === 0 ? ' is-zero' : ''}`}>
            {axisMoney(t, model.currency)}
          </text>
        </g>
      ))}
      {model.periods.map((p, i) => {
        if (!p.count) return null;
        const cx = g.cx(i);
        const y0 = y(0);
        if (p.net === 0) {
          const half = Math.max(bw / 2, 5);
          return <line key={p.key} x1={cx - half} x2={cx + half} y1={y0} y2={y0} className="pf-zero-mark" />;
        }
        const y1 = y(p.net);
        return (
          <g key={p.key}>
            <rect x={cx - bw / 2} y={Math.min(y0, y1)} width={bw} height={Math.max(Math.abs(y1 - y0), 1)} rx={2} className={p.net > 0 ? 'pf-bar-pos' : 'pf-bar-neg'} />
            {p.provisional > 0 && <circle cx={cx} cy={p.net > 0 ? y1 - 7 : y1 + 7} r={2.8} className="pf-prov-dot" />}
          </g>
        );
      })}
      {showXAxis && <XAxis model={model} width={width} y={height - 6} />}
      <HitLayer model={model} width={width} top={top} bottom={bottom} />
    </svg>
  );
}

export function CumulativeChart({ model, width, height, showXAxis = true, tickCount }: ChartProps) {
  const uid = useId().replace(/:/g, '');
  if (width < 60 || height < 50) return null;
  const top = 12;
  const bottom = height - (showXAxis ? 24 : 6);
  const cums = model.periods.map((p) => p.cumulative);
  const { lo, hi, ticks } = niceScale(Math.min(0, ...cums), Math.max(0, ...cums), tickCount ?? (height < 150 ? 2 : 4));
  const y = (v: number) => top + ((hi - v) / (hi - lo)) * (bottom - top);
  const g = bandGeometry(model.periods.length, width);
  const zy = y(0);
  // Step rendering: the running total starts at 0 on the window boundary and changes only where a period has results.
  let d = `M${g.x0},${zy}`;
  model.periods.forEach((p, i) => {
    d += ` H${g.cx(i)} V${y(p.cumulative)}`;
  });
  d += ` H${g.x1}`;
  const area = `${d} V${zy} H${g.x0} Z`;
  const a = model.active;
  return (
    <svg width={width} height={height} className="pf-svg" aria-hidden="true">
      <defs>
        <clipPath id={`above-${uid}`}>
          <rect x={0} y={0} width={width} height={Math.max(zy - 1, 0)} />
        </clipPath>
        <clipPath id={`below-${uid}`}>
          <rect x={0} y={zy + 1} width={width} height={Math.max(height - zy, 0)} />
        </clipPath>
      </defs>
      {a != null && <rect x={g.cx(a) - g.band / 2} y={top} width={g.band} height={bottom - top} className="pf-active-band" />}
      {ticks.map((t) => (
        <g key={t}>
          <line x1={g.x0} x2={g.x1} y1={y(t)} y2={y(t)} className={t === 0 ? 'pf-zero' : 'pf-grid'} />
          <text x={g.x0 - 10} y={y(t)} dy="0.32em" textAnchor="end" className={`pf-ytick${t === 0 ? ' is-zero' : ''}`}>
            {axisMoney(t, model.currency)}
          </text>
        </g>
      ))}
      <path d={area} className="pf-area-pos" clipPath={`url(#above-${uid})`} />
      <path d={area} className="pf-area-neg" clipPath={`url(#below-${uid})`} />
      <path d={d} className="pf-line-base" />
      <path d={d} className="pf-line-pos" clipPath={`url(#above-${uid})`} />
      <path d={d} className="pf-line-neg" clipPath={`url(#below-${uid})`} />
      <circle cx={g.x0} cy={zy} r={3} className="pf-start-dot" />
      {model.periods.map((p, i) =>
        p.count > 0 ? (
          <circle
            key={p.key}
            cx={g.cx(i)}
            cy={y(p.cumulative)}
            r={i === a ? 4.5 : 3}
            className={`pf-step-dot ${p.cumulative > 0 ? 'is-pos' : p.cumulative < 0 ? 'is-neg' : ''}`}
          />
        ) : null,
      )}
      {a != null && <line x1={g.cx(a)} x2={g.cx(a)} y1={top} y2={bottom} className="pf-guide" />}
      {showXAxis && <XAxis model={model} width={width} y={height - 6} />}
      <HitLayer model={model} width={width} top={top} bottom={bottom} />
    </svg>
  );
}

export function chartKeyHandler(model: Model) {
  return (e: KeyboardEvent) => {
    const map: Record<string, number | 'home' | 'end'> = { ArrowLeft: -1, ArrowRight: 1, Home: 'home', End: 'end' };
    if (e.key in map) {
      e.preventDefault();
      model.step(map[e.key], 'chart');
    }
  };
}

export function PeriodReadout({ model }: { model: Model }) {
  const p = model.active != null ? model.periods[model.active] : null;
  if (!p) return null;
  const c = model.currency;
  return (
    <div className="pf-readout" aria-live="polite">
      <strong className="pf-readout-period">
        {p.label}
        {p.partial && <span className="pf-tag">partial</span>}
      </strong>
      {p.count === 0 ? (
        <span>No completed trades · running total stays {money(p.cumulative, c)}</span>
      ) : (
        <>
          <span>
            <b>{p.count}</b> trade{p.count === 1 ? '' : 's'}
          </span>
          <span>
            Gross <b className={signClass(p.gross)}>{money(p.gross, c)}</b>
          </span>
          <span>
            Commission <b>{money(p.commission, c)}</b>
          </span>
          <span>
            Net <b className={signClass(p.net)}>{money(p.net, c)}</b>
          </span>
          <span>
            Running total <b className={signClass(p.cumulative)}>{money(p.cumulative, c)}</b>
          </span>
          {p.provisional > 0 && <span className="pf-evidence-text">{caveatText(p)}</span>}
        </>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ period table */

export function PeriodTable({
  model,
  compact = false,
  inlineBar = false,
  cumulative = false,
  showEmpty,
}: {
  model: Model;
  compact?: boolean;
  inlineBar?: boolean;
  cumulative?: boolean;
  showEmpty: boolean;
}) {
  const m = model;
  const c = m.currency;
  const scrollRef = useRef<HTMLDivElement>(null);
  const rows = m.periods.map((p, i) => ({ p, i })).filter(({ p }) => showEmpty || p.count > 0);
  const maxAbs = Math.max(1, ...m.periods.map((p) => Math.abs(p.net)));

  // Scroll only the table's own panel (never the window) so a selected row stays clear of the sticky header and totals.
  const revealRow = (index: number) => {
    const box = scrollRef.current;
    const row = box?.querySelector<HTMLTableRowElement>(`[data-index="${index}"]`);
    if (!box || !row) return null;
    const head = box.querySelector('thead')?.getBoundingClientRect().height ?? 0;
    const foot = box.querySelector('tfoot')?.getBoundingClientRect().height ?? 0;
    const top = row.getBoundingClientRect().top - box.getBoundingClientRect().top + box.scrollTop;
    const bottom = top + row.getBoundingClientRect().height;
    if (top - head < box.scrollTop) box.scrollTop = top - head;
    else if (bottom + foot > box.scrollTop + box.clientHeight) box.scrollTop = bottom + foot - box.clientHeight;
    return row;
  };

  // A freshly mounted table only becomes scrollable once flex layout constrains it: reveal the selected period then, once.
  const activeRef = useRef(m.active);
  activeRef.current = m.active;
  useEffect(() => {
    const box = scrollRef.current;
    if (!box) return;
    let revealed = false;
    const ro = new ResizeObserver(() => {
      if (revealed || box.scrollHeight <= box.clientHeight || activeRef.current == null) return;
      revealed = true;
      revealRow(activeRef.current);
    });
    ro.observe(box);
    return () => ro.disconnect();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (m.activeSource !== 'chart' || m.active == null) return;
    // Wait for the flex layout to settle so the first reveal lands on the latest period.
    const frame = requestAnimationFrame(() => revealRow(m.active as number));
    return () => cancelAnimationFrame(frame);
  }, [m.active, m.activeSource, showEmpty]); // eslint-disable-line react-hooks/exhaustive-deps

  const onKey = (e: KeyboardEvent<HTMLTableRowElement>, pos: number) => {
    const next = e.key === 'ArrowDown' ? pos + 1 : e.key === 'ArrowUp' ? pos - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? rows.length - 1 : null;
    if (next == null) return;
    e.preventDefault();
    const target = rows[Math.max(0, Math.min(rows.length - 1, next))];
    m.pin(target.i, 'table');
    revealRow(target.i)?.focus({ preventScroll: true });
  };

  const activeVisible = rows.some(({ i }) => i === m.active);

  return (
    <div className="pf-table-scroll" ref={scrollRef} onMouseLeave={() => m.hoverAt(null, 'table')}>
      <table className={`pf-table${compact ? ' is-compact' : ''}`}>
        <caption className="pf-sr">Net P&amp;L by {m.unit}, {c}</caption>
        <thead>
          <tr>
            <th scope="col">{m.unit === 'day' ? 'Day' : m.unit === 'week' ? 'Week' : 'Month'}</th>
            <th scope="col" className="num">
              Trades
            </th>
            <th scope="col" className="num">
              Gross P&amp;L
            </th>
            <th scope="col" className="num">
              {compact ? 'Comm.' : 'Commission'}
            </th>
            <th scope="col" className="num">
              Net P&amp;L
            </th>
            {inlineBar && (
              <th scope="col" className="pf-bar-col">
                <span className="pf-sr">Net P&amp;L bar</span>
              </th>
            )}
            {cumulative && (
              <th scope="col" className="num">
                Running total
              </th>
            )}
            <th scope="col">{compact ? <span className="pf-sr">Notes</span> : 'Notes'}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(({ p, i }, pos) => {
            const empty = p.count === 0;
            const isActive = i === m.active;
            const notes = empty ? 'No completed trades' : caveatText(p);
            return (
              <tr
                key={p.key}
                data-index={i}
                className={`${isActive ? 'is-active' : ''}${empty ? ' is-empty' : ''}`}
                tabIndex={isActive || (!activeVisible && pos === 0) ? 0 : -1}
                aria-selected={isActive}
                onMouseEnter={() => m.hoverAt(i, 'table')}
                onClick={() => m.pin(i, 'table')}
                onFocus={() => m.pin(i, 'table')}
                onKeyDown={(e) => onKey(e, pos)}
              >
                <th scope="row">
                  {p.label}
                  {p.partial && <span className="pf-tag">partial</span>}
                </th>
                <td className="num">{empty ? '—' : p.count}</td>
                <td className={`num ${signClass(p.gross)}`}>{empty ? '—' : money(p.gross, c)}</td>
                <td className="num">{empty ? '—' : money(p.commission, c)}</td>
                <td className={`num pf-strong ${signClass(p.net)}`}>{empty ? '—' : money(p.net, c)}</td>
                {inlineBar && (
                  <td className="pf-bar-col" aria-hidden="true">
                    <span className="pf-inline-track">
                      <span className="pf-inline-zero" />
                      {!empty && p.net !== 0 && (
                        <span
                          className={`pf-inline-bar ${p.net > 0 ? 'is-pos' : 'is-neg'}`}
                          style={
                            p.net > 0
                              ? { left: '50%', width: `${(Math.abs(p.net) / maxAbs) * 50}%` }
                              : { right: '50%', width: `${(Math.abs(p.net) / maxAbs) * 50}%` }
                          }
                        />
                      )}
                      {!empty && p.net === 0 && <span className="pf-inline-zero-mark" />}
                    </span>
                  </td>
                )}
                {cumulative && <td className={`num ${signClass(p.cumulative)}`}>{money(p.cumulative, c)}</td>}
                <td className={`pf-notes${!empty && notes ? ' pf-evidence-text' : ''}`}>
                  {compact ? (
                    notes && !empty ? (
                      <span className="pf-note-mark" title={notes}>
                        <span aria-hidden="true">◦</span>
                        <span className="pf-sr">{notes}</span>
                      </span>
                    ) : null
                  ) : (
                    notes
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr>
            <th scope="row">Total</th>
            <td className="num">{m.totals.count}</td>
            <td className={`num ${signClass(m.totals.gross)}`}>{money(m.totals.gross, c)}</td>
            <td className="num">{money(m.totals.commission, c)}</td>
            <td className={`num pf-strong ${signClass(m.totals.net)}`}>{money(m.totals.net, c)}</td>
            {inlineBar && <td className="pf-bar-col" />}
            {cumulative && <td className={`num ${signClass(m.totals.net)}`}>{money(m.totals.net, c)}</td>}
            <td className={`pf-notes${m.totals.provisional ? ' pf-evidence-text' : ''}`}>
              {compact ? (m.totals.provisional ? <span className="pf-note-mark" title={caveatText(m.totals)}>◦</span> : null) : caveatText(m.totals)}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

export function EmptyToggle({ checked, onChange, unit }: { checked: boolean; onChange: (v: boolean) => void; unit: string }) {
  return (
    <label className="pf-check">
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span>Show {unit}s without trades</span>
    </label>
  );
}
