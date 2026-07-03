import { useStore } from '../state/store';

export function LayoutSidebar() {
  const { samples, layoutItems, mainView, setMainView, focusLayoutItem, removeLayoutItem } = useStore();

  return (
    <div className="layout-sidebar">
      <div className="panel-title-row">
        <div className="panel-title">Layout</div>
        <button
          className={`btn btn-small ${mainView === 'layout' ? 'btn-active' : ''}`}
          onClick={() => setMainView(mainView === 'layout' ? 'samples' : 'layout')}
        >
          {mainView === 'layout' ? '← Samples' : 'View Layout →'}
        </button>
      </div>
      {layoutItems.length === 0 ? (
        <p className="layout-sidebar-hint">
          Build a publish-quality figure by adding panels from any sample. Click <strong>⊞</strong> in a panel's header to add it here.
        </p>
      ) : (
        <ul className="gate-list">
          {layoutItems.map((item) => {
            const sampleName = samples.find((s) => s.id === item.sampleId)?.fileName ?? 'removed sample';
            return (
              <li key={item.id} className="gate-item">
                <span
                  className="gate-name"
                  onClick={() => {
                    setMainView('layout');
                    focusLayoutItem(item.id);
                  }}
                  title={`From ${sampleName} · click to view in Layout`}
                >
                  {item.label}
                </span>
                <span className="gate-count">{sampleName}</span>
                <button className="gate-delete" title="Remove from layout" onClick={() => removeLayoutItem(item.id)}>
                  ×
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
