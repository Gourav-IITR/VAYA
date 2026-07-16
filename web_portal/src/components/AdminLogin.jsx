import { useState } from 'react';
import { loginWithEmail, logoutAdmin } from '../shared/firebaseAuth';
import VayaLogo from './VayaLogo';
import { Lock, Mail } from 'lucide-react';

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
      minHeight: '100vh', width: '100vw', backgroundColor: '#F4EFE6',
      fontFamily: 'var(--font-sans)', padding: '16px'
    }}>
      <div style={{
        maxWidth: '420px', width: '100%',
        backgroundColor: '#ffffff', border: '1px solid #E4DFD6',
        borderRadius: '20px', padding: '36px', boxShadow: 'var(--shadow-lg)'
      }}>
        {/* Header Branding */}
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginBottom: '32px' }}>
          <VayaLogo variant="stacked" size={48} />
          <p style={{ fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.15em', color: '#3C3A34', marginTop: '12px', fontWeight: 'bold' }}>
            OPERATIONS HUB
          </p>
        </div>

        {/* Login Form */}
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            <label style={{ fontSize: '11px', fontWeight: 700, color: '#3C3A34', letterSpacing: '0.1em' }}>
              ADMIN EMAIL
            </label>
            <div style={{ position: 'relative' }}>
              <Mail size={16} style={{ position: 'absolute', left: '14px', top: '50%', transform: 'translateY(-50%)', color: '#3C3A34' }} />
              <input
                type="email"
                placeholder="admin@vaya.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                style={{
                  width: '100%', padding: '12px 16px 12px 42px',
                  backgroundColor: '#F4EFE6', border: '1px solid #E4DFD6',
                  borderRadius: '12px', color: '#0E0E0C', fontSize: '14px',
                  outline: 'none', transition: 'border-color 0.2s',
                  fontFamily: 'var(--font-sans)',
                  fontWeight: 600
                }}
                required
              />
            </div>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            <label style={{ fontSize: '11px', fontWeight: 700, color: '#3C3A34', letterSpacing: '0.1em' }}>
              PASSWORD
            </label>
            <div style={{ position: 'relative' }}>
              <Lock size={16} style={{ position: 'absolute', left: '14px', top: '50%', transform: 'translateY(-50%)', color: '#3C3A34' }} />
              <input
                type="password"
                placeholder="••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                style={{
                  width: '100%', padding: '12px 16px 12px 42px',
                  backgroundColor: '#F4EFE6', border: '1px solid #E4DFD6',
                  borderRadius: '12px', color: '#0E0E0C', fontSize: '14px',
                  outline: 'none', transition: 'border-color 0.2s',
                  fontFamily: 'var(--font-sans)'
                }}
                required
              />
            </div>
          </div>

          {errorMsg && (
            <div style={{
              fontSize: '13px', color: '#ef4444', backgroundColor: 'rgba(239, 68, 68, 0.05)',
              padding: '10px 14px', borderRadius: '8px', border: '1px solid rgba(239, 68, 68, 0.1)'
            }}>
              {errorMsg}
            </div>
          )}

          <button
            type="submit"
            disabled={isLoading}
            className="btn btn-primary"
            style={{
              padding: '14px', backgroundColor: '#F26430',
              color: '#fff', border: 'none', borderRadius: '12px',
              fontWeight: 'bold', fontSize: '14px', cursor: 'pointer',
              display: 'flex', justifyContent: 'center', alignItems: 'center', gap: '8px',
              transition: 'background 0.2s', marginTop: '8px',
              fontFamily: 'var(--font-sans)'
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
