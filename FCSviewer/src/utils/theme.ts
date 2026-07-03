/** Color palette for re-rendering a plot panel onto an export canvas, independent of the app's own (always-dark) UI chrome. */
export interface PlotTheme {
  pageBg: string;
  panelBg: string;
  panelBorder: string;
  plotBg: string;
  plotBorder: string;
  tickText: string;
  axisLabelText: string;
  titleText: string;
  subtitleText: string;
  connectorStroke: string;
  defaultGateColor: string;
  defaultHistogramColor: string;
  annotationBg: string;
  annotationBorder: string;
  annotationText: string;
  statsLabelText: string;
  statsValueText: string;
}

export const DARK_THEME: PlotTheme = {
  pageBg: '#16171d',
  panelBg: '#1a1b22',
  panelBorder: '#2e303a',
  plotBg: '#1a1b22',
  plotBorder: '#3a3f4b',
  tickText: '#9aa4b2',
  axisLabelText: '#c7cdd6',
  titleText: '#e5e7eb',
  subtitleText: '#8b93a1',
  connectorStroke: '#4b5160',
  defaultGateColor: '#2ee6a6',
  defaultHistogramColor: '#4f8dff',
  annotationBg: 'rgba(10, 11, 15, 0.72)',
  annotationBorder: 'rgba(255, 255, 255, 0.15)',
  annotationText: '#e5e7eb',
  statsLabelText: '#6b7280',
  statsValueText: '#9aa4b2',
};

export const LIGHT_THEME: PlotTheme = {
  pageBg: '#ffffff',
  panelBg: '#ffffff',
  panelBorder: '#d1d5db',
  plotBg: '#ffffff',
  plotBorder: '#94a3b8',
  tickText: '#374151',
  axisLabelText: '#111827',
  titleText: '#111827',
  subtitleText: '#4b5563',
  connectorStroke: '#6b7280',
  defaultGateColor: '#0f9d68',
  defaultHistogramColor: '#2563eb',
  annotationBg: 'rgba(255, 255, 255, 0.88)',
  annotationBorder: 'rgba(0, 0, 0, 0.25)',
  annotationText: '#111827',
  statsLabelText: '#6b7280',
  statsValueText: '#374151',
};

export type ExportThemeName = 'dark' | 'light';

export function getExportTheme(name: ExportThemeName): PlotTheme {
  return name === 'light' ? LIGHT_THEME : DARK_THEME;
}
