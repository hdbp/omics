import { useStore } from '../state/store';

/**
 * Free-text notes about the assay/experiment (protocol, panel design, deviations, etc.),
 * shared across every loaded sample and saved with the project file — a lightweight
 * electronic-notebook entry alongside the gating workspace and Layout collage.
 */
export function Notebook() {
  const { notebookText, updateNotebookText } = useStore();

  return (
    <div className="panel-workspace-wrap notebook-wrap">
      <div className="panel-workspace-toolbar">
        <span className="workspace-title">Notebook · notes about this assay</span>
        <span className="workspace-title">{notebookText.length.toLocaleString()} characters</span>
      </div>
      <textarea
        className="notebook-textarea"
        value={notebookText}
        onChange={(e) => updateNotebookText(e.target.value)}
        placeholder={
          'Notes about this assay — panel design, antibody/fluorophore choices, compensation notes, ' +
          'run conditions, deviations from protocol, anything worth remembering next time you open this project…'
        }
        spellCheck
      />
    </div>
  );
}
