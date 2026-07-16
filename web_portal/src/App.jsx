import { useState, useEffect } from 'react';
import AdminDashboard from './components/AdminDashboard';
import AdminLogin from './components/AdminLogin';
import VayaLogo from './components/VayaLogo';
import { onAuthChange, logoutAdmin } from './shared/firebaseAuth';
import { LogOut, Monitor } from 'lucide-react';

export default function App() {
  const [adminUser, setAdminUser] = useState(null);
  const [isInitializing, setIsInitializing] = useState(true);

  useEffect(() => {
    const unsubscribe = onAuthChange(async (user) => {
      if (user) {
        try {
          const tokenResult = await user.getIdTokenResult();
          const role = tokenResult.claims?.role;
          if (role === 'admin') {
            setAdminUser(user);
          } else {
            await logoutAdmin();
            setAdminUser(null);
          }
        } catch (err) {
          console.error('Auth verification error:', err);
          setAdminUser(null);
        }
      } else {
        setAdminUser(null);
      }
      setIsInitializing(false);
    });

    return () => unsubscribe();
  }, []);

  const handleLogout = async () => {
    await logoutAdmin();
    setAdminUser(null);
  };

  if (isInitializing) {
    return (
      <div style={{
        display: 'flex', justifyContent: 'center', alignItems: 'center',
        height: '100vh', width: '100vw', backgroundColor: '#F4EFE6', color: '#0E0E0C'
      }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '16px' }}>
          <div style={{
            width: '28px', height: '28px', border: '3px solid #0E0E0C',
            borderTopColor: '#F26430', borderRadius: '50%',
            animation: 'spin 1s linear infinite'
          }} />
          <span style={{ fontSize: '13px', fontWeight: 600, color: '#3C3A34' }}>Verifying VAYA Operations...</span>
        </div>
      </div>
    );
  }

  if (!adminUser) {
    return <AdminLogin onLoginSuccess={setAdminUser} />;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100vh', width: '100vw', overflow: 'hidden' }}>
      
      {/* Platform Navigation Header */}
      <header style={{ 
        display: 'flex', justifyContent: 'space-between', alignItems: 'center', 
        padding: '12px 24px', background: '#fff', borderBottom: '1px solid var(--border-color)', 
        boxShadow: 'var(--shadow-sm)', zIndex: 100 
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <VayaLogo size={28} />
        </div>

        {/* Administration header actions */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginRight: '8px' }}>
            <Monitor size={15} style={{ color: 'var(--slate)' }} />
            <span style={{ fontSize: '13px', fontWeight: 600, color: 'var(--slate)' }}>Control Terminal</span>
          </div>

          <button 
            onClick={handleLogout}
            className="btn btn-secondary"
            style={{ padding: '8px 14px', fontSize: '13px', display: 'flex', alignItems: 'center', gap: '6px' }}
          >
            <LogOut size={14} />
            <span>Sign Out</span>
          </button>
        </div>
      </header>

      {/* Main Display Pane */}
      <main style={{ flex: 1, overflow: 'hidden', backgroundColor: 'var(--bg-primary)' }}>
        <AdminDashboard adminUser={adminUser} />
      </main>

    </div>
  );
}
