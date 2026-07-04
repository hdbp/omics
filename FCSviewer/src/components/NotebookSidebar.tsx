import { useStore } from '../state/store';

/** Sidebar entry point for the Notebook: a title, a short preview of the current notes, and a view-switcher button. */
export function NotebookSidebar() {
  const { mainView, setMainView, notebookText } = useStore();
  const firstLine = notebookText.trim().split('\n')[0];

  return (
    <div className="notebook-sidebar">
      <div className="panel-title-row">
        <div className="panel-title">Notebook</div>
        <button
          className={`btn btn-small ${mainView === 'notebook' ? 'btn-active' : ''}`}
          onClick={() => setMainView(mainView === 'notebook' ? 'samples' : 'notebook')}
        >
          {mainView === 'notebook' ? '← Samples' : 'View Notebook →'}
        </button>
      </div>
      <p className="layout-sidebar-hint">{firstLine || 'Jot down notes about this assay — protocol, panel design, deviations.'}</p>
    </div>
  );
}
