import { useState } from 'react';
import {
  AppShell,
  CumulativeChart,
  EmptyToggle,
  PeriodBarsChart,
  PeriodReadout,
  PeriodTable,
  ReportFrame,
  chartKeyHandler,
  money,
  shortDate,
  useElementSize,
  usePerformanceModel,
  type Model,
} from './perf-shared';
import './PerformanceAAlignedTimeline.css';

/**
 * Proposal A — Aligned Timeline.
 * One wide analysis panel: the running total and each period's net bars share a single
 * time axis, so a step in the line sits directly above the bar that caused it.
 * Text is kept out of the chart's height: one heading row with the legend, and chart labels
 * set inside the plot. The supporting period table is one switch away, keeps the same
 * selection, and opens on the selected period.
 */
function TimelinePanel({ model }: { model: Model }) {
  const m = model;
  const c = m.currency;
  const [view, setView] = useState<'chart' | 'table'>('chart');
  const [showEmpty, setShowEmpty] = useState(true);
  const [chartRef, size] = useElementSize<HTMLDivElement>();
  const gap = 12;
  const avail = Math.max(size.h - gap, 0);
  const cumH = Math.round(avail * 0.56);
  const barsH = avail - cumH;
  const anyProvisional = m.periods.some((p) => p.provisional > 0);

  return (
    <section className="pf-panel pf-a-panel" aria-labelledby="pf-a-title">
      <div className="pf-a-head">
        <h3 id="pf-a-title">Net P&amp;L by {m.unit}</h3>
        {view === 'chart' ? (
          <div className="pf-legend" aria-hidden="true">
            <span>
              <i className="pf-key-line" />
              Running total from {money(0, c)} on {shortDate(m.range.from)}
            </span>
            <span>
              <i className="pf-key-bar" />
              Net per {m.unit}, after commission
            </span>
            {anyProvisional && (
              <span>
                <i className="pf-key-dot" />
                Fees may update
              </span>
            )}
          </div>
        ) : (
          <EmptyToggle checked={showEmpty} onChange={setShowEmpty} unit={m.unit} />
        )}
        <div className="pf-seg is-small" role="group" aria-label="Show results as">
          <button type="button" aria-pressed={view === 'chart'} onClick={() => setView('chart')}>
            Chart
          </button>
          <button type="button" aria-pressed={view === 'table'} onClick={() => setView('table')}>
            Table
          </button>
        </div>
      </div>

      {view === 'chart' ? (
        <div
          ref={chartRef}
          className="pf-chart-focus pf-a-charts"
          tabIndex={0}
          role="group"
          aria-label={`Running total from ${money(0, c)} and net P&L by ${m.unit}. Use the left and right arrow keys to move between ${m.unit}s; details are read below the chart.`}
          onKeyDown={chartKeyHandler(m)}
          onMouseLeave={() => m.hoverAt(null, 'chart')}
        >
          <div className="pf-a-chart">
            <span className="pf-a-chart-label">Running total</span>
            <CumulativeChart model={m} width={size.w} height={cumH} showXAxis={false} />
          </div>
          <div className="pf-a-chart" style={{ marginTop: gap }}>
            <span className="pf-a-chart-label">Net per {m.unit}</span>
            <PeriodBarsChart model={m} width={size.w} height={barsH} />
          </div>
        </div>
      ) : (
        <div className="pf-a-table">
          <PeriodTable model={m} cumulative showEmpty={showEmpty} />
        </div>
      )}
      <PeriodReadout model={m} />
    </section>
  );
}

export const PerformanceAAlignedTimeline = () => {
  const model = usePerformanceModel();
  return (
    <AppShell model={model}>
      <ReportFrame model={model} compactEvidence>
        <TimelinePanel model={model} />
      </ReportFrame>
    </AppShell>
  );
};
