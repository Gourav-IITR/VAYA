import { useState } from 'react';
import { loginWithEmail, logoutAdmin } from '../shared/firebaseAuth';
import { Lock, Mail, Truck } from 'lucide-react';

export default function AdminLogin({ onLoginSuccess }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState(null);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!email || !password) {
      setErrorMsg('Please enter both email and password.');
      return;
    }

    setIsLoading(true);
    setErrorMsg(null);

    try {
      const user = await loginWithEmail(email, password);
      const tokenResult = await user.getIdTokenResult();
      const role = tokenResult.claims?.role;

      if (role === 'admin') {
        onLoginSuccess(user);
      } else {
        setErrorMsg('Access Denied: You do not have administrator privileges.');
        await logoutAdmin();
      }
    } catch (err) {
      setErrorMsg(err.message || 'Invalid administrator credentials.');
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div style={{
      display: 'flex', justifyContent: 'center', alignItems: 'center',
      minHeight: '100vh', width: '100vw', backgroundColor: '#0f172a',
      fontFamily: 'var(--font-body)', padding: '16px'
    }}>
      <div style={{
        maxWidth: '420px', width: '100%',
        backgroundColor: '#1e293b', border: '1px solid #334155',
        borderRadius: '16px', padding: '36px', boxShadow: 'var(--shadow-lg)'
      }}>
        {/* Header Branding */}
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginBottom: '32px' }}>
          <div style={{
            padding: '12px', borderRadius: '12px',
            backgroundColor: 'rgba(249, 115, 22, 0.1)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            marginBottom: '16px'
          }}>
            <Truck size={32} style={{ color: 'var(--primary)' }} />
          </div>
          <h1 style={{
            fontFamily: 'var(--font-display)', fontWeight: 800, fontSize: '28px',
            color: '#fff', margin: 0, textAlign: 'center', letterSpacing: '0.05em'
          }}>
            VAYA
          </h1>
          <p style={{ fontSize: '13px', color: '#f97316', marginTop: '6px', textAlign: 'center', fontWeight: 'bold' }}>
            Vehicle at Your Address
          </p>
        </div>

        {/* Login Form */}
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            <label style={{ fontSize: '12px', fontWeight: 600, color: '#94a3b8' }}>
              ADMIN EMAIL
            </label>
            <div style={{ position: 'relative' }}>
              <Mail size={16} style={{ position: 'absolute', left: '14px', top: '50%', transform: 'translateY(-50%)', color: '#64748b' }} />
              <input
                type="email"
                placeholder="admin@vaya.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                style={{
                  width: '100%', padding: '12px 16px 12px 42px',
                  backgroundColor: '#0f172a', border: '1px solid #334155',
                  borderRadius: '8px', color: '#fff', fontSize: '14px',
                  outline: 'none', transition: 'border-color 0.2s'
                }}
                required
              />
            </div>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            <label style={{ fontSize: '12px', fontWeight: 600, color: '#94a3b8' }}>
              PASSWORD
            </label>
            <div style={{ position: 'relative' }}>
              <Lock size={16} style={{ position: 'absolute', left: '14px', top: '50%', transform: 'translateY(-50%)', color: '#64748b' }} />
              <input
                type="password"
                placeholder="••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                style={{
                  width: '100%', padding: '12px 16px 12px 42px',
                  backgroundColor: '#0f172a', border: '1px solid #334155',
                  borderRadius: '8px', color: '#fff', fontSize: '14px',
                  outline: 'none', transition: 'border-color 0.2s'
                }}
                required
              />
            </div>
          </div>

          {errorMsg && (
            <div style={{
              fontSize: '13px', color: '#ef4444', backgroundColor: 'rgba(239, 68, 68, 0.1)',
              padding: '10px 14px', borderRadius: '6px', border: '1px solid rgba(239, 68, 68, 0.2)'
            }}>
              {errorMsg}
            </div>
          )}

          <button
            type="submit"
            disabled={isLoading}
            style={{
              padding: '14px', backgroundColor: 'var(--primary)',
              color: '#fff', border: 'none', borderRadius: '8px',
              fontWeight: 'bold', fontSize: '14px', cursor: 'pointer',
              display: 'flex', justifyContent: 'center', alignItems: 'center', gap: '8px',
              transition: 'background 0.2s', marginTop: '8px'
            }}
          >
            {isLoading ? (
              <span className="spinner" style={{
                width: '16px', height: '16px', border: '2px solid #fff',
                borderTopColor: 'transparent', borderRadius: '50%', display: 'inline-block',
                animation: 'spin 1s linear infinite'
              }} />
            ) : (
              'Sign In to Dashboard'
            )}
          </button>
        </form>
      </div>
    </div>
  );
}
