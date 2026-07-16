import { StrictMode, Component } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'

// ─── Error Boundary ───────────────────────────────────────────────────────────
class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }

  componentDidCatch(error, info) {
    console.error('💥 App crashed:', error, info);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          justifyContent: 'center', height: '100vh', gap: '16px',
          fontFamily: 'Inter, sans-serif', background: '#f8fafc', padding: '24px'
        }}>
          <div style={{ fontSize: '48px' }}>🚚</div>
          <h1 style={{ fontSize: '24px', color: '#1e293b', margin: 0 }}>
            Something went wrong
          </h1>
          <p style={{ color: '#64748b', textAlign: 'center', maxWidth: '400px' }}>
            The app encountered an error. Make sure the backend server is running:
          </p>
          <code style={{
            background: '#1e293b', color: '#94a3b8', padding: '12px 20px',
            borderRadius: '8px', fontSize: '13px'
          }}>
            cd backend && node server.js
          </code>
          <details style={{ color: '#ef4444', fontSize: '12px', maxWidth: '500px' }}>
            <summary style={{ cursor: 'pointer' }}>Error details</summary>
            <pre style={{ whiteSpace: 'pre-wrap', marginTop: '8px' }}>
              {this.state.error?.toString()}
            </pre>
          </details>
          <button
            onClick={() => window.location.reload()}
            style={{
              background: '#f97316', color: '#fff', border: 'none',
              padding: '10px 24px', borderRadius: '8px', cursor: 'pointer',
              fontWeight: 600, fontSize: '14px'
            }}
          >
            Reload Page
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
)
