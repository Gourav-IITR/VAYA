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
          fontFamily: 'Inter, sans-serif', background: '#F4EFE6', padding: '24px'
        }}>
          <div style={{ fontSize: '48px', color: '#F26430', fontWeight: 'bold' }}>V</div>
          <h1 style={{ fontSize: '24px', color: '#0E0E0C', margin: 0 }}>
            Something went wrong
          </h1>
          <p style={{ color: '#3C3A34', textAlign: 'center', maxWidth: '400px' }}>
            The VAYA platform encountered an issue. Make sure the server is online.
          </p>
          <button
            onClick={() => window.location.reload()}
            style={{
              background: '#F26430', color: '#fff', border: 'none',
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
