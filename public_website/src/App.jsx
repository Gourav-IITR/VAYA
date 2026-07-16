import React, { useState } from 'react';
import VayaLogo from './components/VayaLogo';
import { 
  Shield, 
  MapPin, 
  Clock, 
  CheckCircle, 
  ChevronRight, 
  Menu, 
  X,
  Truck,
  ArrowRight,
  TrendingUp,
  Compass
} from 'lucide-react';

export default function App() {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [trackBookingId, setTrackBookingId] = useState('');
  const [trackResult, setTrackResult] = useState(null);
  const [trackError, setTrackError] = useState('');

  const handleTrackSubmit = async (e) => {
    e.preventDefault();
    if (!trackBookingId) return;
    setTrackError('');
    setTrackResult(null);
    try {
      // Simulate real-time tracking search lookup call
      const res = await fetch(`http://localhost:5001/api/booking/status-public?bookingId=${trackBookingId}`);
      if (res.ok) {
        const data = await res.json();
        setTrackResult(data.booking);
      } else {
        setTrackError('Active booking ID not found. Verify the ID and try again.');
      }
    } catch (err) {
      setTrackError('Connection error. Verify that the VAYA server is online.');
    }
  };

  return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
      
      {/* Top Header Navigation */}
      <header>
        <div className="nav-container">
          <a href="/" className="logo-link">
            <VayaLogo size={36} />
          </a>

          {/* Desktop Nav */}
          <nav className="nav-menu" style={{ display: 'none', mdDisplay: 'flex' }}>
            <a href="#business">For Business</a>
            <a href="#drivers">Drivers</a>
            <a href="#vehicles">Vehicles</a>
            <a href="#track">Track</a>
            <a href="#book" className="nav-cta">Book a VAYA</a>
          </nav>

          {/* Mobile Menu Toggle */}
          <button 
            onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
            style={{ 
              display: 'block', 
              background: 'none', 
              border: 'none', 
              cursor: 'pointer',
              color: 'var(--ink-black)'
            }}
            className="md-hide"
          >
            {mobileMenuOpen ? <X size={24} /> : <Menu size={24} />}
          </button>
        </div>

        {/* Mobile Navigation Panel */}
        {mobileMenuOpen && (
          <div style={{
            backgroundColor: 'var(--signal-cream)',
            borderBottom: '1px solid var(--fog)',
            padding: '24px',
            display: 'flex',
            flexDirection: 'column',
            gap: '18px'
          }}>
            <a href="#business" onClick={() => setMobileMenuOpen(false)} style={{ textDecoration: 'none', color: 'var(--slate)', fontWeight: 600 }}>For Business</a>
            <a href="#drivers" onClick={() => setMobileMenuOpen(false)} style={{ textDecoration: 'none', color: 'var(--slate)', fontWeight: 600 }}>Drivers</a>
            <a href="#vehicles" onClick={() => setMobileMenuOpen(false)} style={{ textDecoration: 'none', color: 'var(--slate)', fontWeight: 600 }}>Vehicles</a>
            <a href="#track" onClick={() => setMobileMenuOpen(false)} style={{ textDecoration: 'none', color: 'var(--slate)', fontWeight: 600 }}>Track Delivery</a>
            <a href="#book" onClick={() => setMobileMenuOpen(false)} className="nav-cta" style={{ textAlign: 'center' }}>Book a VAYA</a>
          </div>
        )}
      </header>

      {/* Main Hero Section */}
      <main style={{ flex: 1 }}>
        <section className="hero-section">
          <div className="hero-content">
            <div className="section-label">INTRODUCING VAYA</div>
            <h1 className="hero-title">
              Your vehicle.<br />
              At your address.<br />
              In minutes.
            </h1>
            <p className="hero-subtitle">
              Move anything across the city, bike to mini-truck, upfront-priced and live-tracked.
            </p>
            <div className="hero-ctas">
              <a href="#book" className="btn-primary">Book a VAYA</a>
              <a href="#business" className="btn-secondary">For business</a>
            </div>
          </div>
          <div className="hero-image-container">
            <img 
              src="/vaya-rider-hero.png" 
              alt="VAYA delivery partner riding scooter through urban city" 
              className="hero-image"
            />
          </div>
        </section>

        {/* Stats Strip */}
        <section className="stats-strip">
          <div className="stats-container">
            <div className="stat-item">
              <span className="stat-num">12 LAKH+</span>
              <span className="stat-label">Trips Delivered</span>
            </div>
            <div className="stat-item">
              <span className="stat-num">200+</span>
              <span className="stat-label">Pin Codes Active</span>
            </div>
            <div className="stat-item">
              <span className="stat-num">&lt;3 MIN</span>
              <span className="stat-label">Avg Match Time</span>
            </div>
            <div className="stat-item">
              <span className="stat-num">99.4%</span>
              <span className="stat-label">On-Time Success</span>
            </div>
          </div>
        </section>

        {/* How VAYA Works */}
        <section className="section" id="how-it-works">
          <div style={{ textAlign: 'center', marginBottom: '60px' }}>
            <div className="section-label">OPERATIONAL EASE</div>
            <h2 className="section-title" style={{ marginBottom: '16px' }}>How VAYA Works</h2>
            <p style={{ color: 'var(--slate)', fontSize: '16px', maxWidth: '600px', margin: '0 auto' }}>
              We've redesigned municipal logistics from the ground up, making cargo movement as simple as hailing a ride.
            </p>
          </div>

          <div className="process-grid">
            <div className="process-card">
              <div className="process-num">01</div>
              <h3 className="process-title">Request in Seconds</h3>
              <p className="process-desc">
                Select your cargo size, input coordinates, and view your exact upfront price estimate immediately. No hidden charges.
              </p>
            </div>
            <div className="process-card">
              <div className="process-num">02</div>
              <h3 className="process-title">Instant Matching</h3>
              <p className="process-desc">
                Our smart dispatch network maps your order to the nearest verified driver within 3km, locked inside secure transactions.
              </p>
            </div>
            <div className="process-card">
              <div className="process-num">03</div>
              <h3 className="process-title">Track & Verify</h3>
              <p className="process-desc">
                Watch the vehicle move in real-time. Lock the shipment using a 6-digit OTP verification key checked on cargo pickup.
              </p>
            </div>
          </div>
        </section>

        {/* Vehicle Options */}
        <section className="section" id="vehicles" style={{ backgroundColor: 'rgba(228, 223, 214, 0.3)', borderRadius: '32px' }}>
          <div style={{ textAlign: 'center', marginBottom: '60px' }}>
            <div className="section-label">FLEET SIZE</div>
            <h2 className="section-title" style={{ marginBottom: '16px' }}>VAYA Vehicle Options</h2>
            <p style={{ color: 'var(--slate)', fontSize: '16px', maxWidth: '600px', margin: '0 auto' }}>
              Choose the capacity that fits your load. From envelopes to commercial freight.
            </p>
          </div>

          <div className="vehicle-grid">
            <div className="vehicle-card">
              <div className="vehicle-icon-wrapper">
                <Truck size={32} style={{ color: 'var(--primary)' }} />
              </div>
              <h3 className="vehicle-title">Two-Wheeler (Bike)</h3>
              <div className="vehicle-capacity">Capacity &lt; 20 kg</div>
              <p className="vehicle-desc">
                Perfect for quick document handoffs, restaurant supplies, parcel courier items, and small boxes.
              </p>
            </div>
            <div className="vehicle-card">
              <div className="vehicle-icon-wrapper">
                <Truck size={32} style={{ color: 'var(--primary)' }} />
              </div>
              <h3 className="vehicle-title">Mini Truck (Tata Ace)</h3>
              <div className="vehicle-capacity">Capacity &lt; 500 kg</div>
              <p className="vehicle-desc">
                Designed for bulk deliveries, apartment relocations, heavy commercial goods, and retail distributions.
              </p>
            </div>
            <div className="vehicle-card">
              <div className="vehicle-icon-wrapper">
                <Truck size={32} style={{ color: 'var(--primary)' }} />
              </div>
              <h3 className="vehicle-title">Large Truck (Tata 407)</h3>
              <div className="vehicle-capacity">Capacity &lt; 2.0 t</div>
              <p className="vehicle-desc">
                Commercial grade heavy logistics carrier for enterprise cargo, factory supplies, and industrial shipments.
              </p>
            </div>
          </div>
        </section>

        {/* Real-time Tracking Widget */}
        <section className="section" id="track">
          <div style={{
            backgroundColor: 'white',
            borderRadius: '24px',
            border: '1px solid var(--fog)',
            padding: '48px',
            maxWidth: '720px',
            margin: '0 auto',
            boxShadow: 'var(--shadow-lg)'
          }}>
            <div style={{ textAlign: 'center', marginBottom: '24px' }}>
              <div className="section-label">REAL-TIME MONITOR</div>
              <h2 style={{ fontFamily: 'var(--font-display)', fontWeight: 800, fontSize: '28px', color: 'var(--ink-black)' }}>
                Track Your VAYA
              </h2>
              <p style={{ color: 'var(--slate)', fontSize: '14px', marginTop: '6px' }}>
                Enter your 8-character active booking ID to view live operational status.
              </p>
            </div>

            <form onSubmit={handleTrackSubmit} style={{ display: 'flex', gap: '12px' }}>
              <input 
                type="text" 
                placeholder="e.g. vaya-book-123" 
                value={trackBookingId}
                onChange={(e) => setTrackBookingId(e.target.value)}
                style={{
                  flex: 1,
                  padding: '16px 20px',
                  borderRadius: '12px',
                  border: '1px solid var(--fog)',
                  outline: 'none',
                  fontSize: '15px'
                }}
                required
              />
              <button type="submit" className="btn-primary" style={{ borderRadius: '12px', padding: '16px 28px' }}>
                Locate
              </button>
            </form>

            {trackError && (
              <div style={{ color: 'red', marginTop: '16px', fontSize: '13px', textAlign: 'center' }}>
                {trackError}
              </div>
            )}

            {trackResult && (
              <div style={{ 
                marginTop: '32px', 
                padding: '24px', 
                backgroundColor: 'var(--signal-cream)', 
                borderRadius: '16px',
                border: '1px solid var(--fog)'
              }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '12px' }}>
                  <span style={{ fontWeight: 'bold' }}>Status:</span>
                  <span style={{ 
                    color: 'var(--primary)', 
                    fontWeight: 'bold', 
                    textTransform: 'uppercase' 
                  }}>{trackResult.status.replace('_', ' ')}</span>
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '12px' }}>
                  <span style={{ fontWeight: 'bold' }}>Route:</span>
                  <span style={{ fontSize: '13px', color: 'var(--slate)' }}>{trackResult.pickup_name} ➔ {trackResult.dropoff_name}</span>
                </div>
                {trackResult.driver_name && (
                  <div style={{ display: 'flex', justifyContent: 'space-between', borderTop: '1px solid var(--fog)', paddingTop: '12px' }}>
                    <span style={{ fontWeight: 'bold' }}>Partner:</span>
                    <span>{trackResult.driver_name} ({trackResult.driver_plate})</span>
                  </div>
                )}
              </div>
            )}
          </div>
        </section>

        {/* Business and Driver Signup banners */}
        <section className="section" id="business">
          <div className="signup-banner">
            <div className="signup-content">
              <h2 className="signup-title">VAYA for Business</h2>
              <p className="signup-desc">
                Streamline your enterprise distribution channels. Manage bulk orders, unified monthly billing options, customizable API payloads, and priority match queues.
              </p>
            </div>
            <div>
              <a href="mailto:business@vaya.in" className="btn-primary" style={{ backgroundColor: 'white', color: 'var(--ink-black)' }}>
                Contact Sales
              </a>
            </div>
          </div>

          <div className="signup-banner" id="drivers" style={{ backgroundColor: 'var(--primary)', marginBottom: '0' }}>
            <div className="signup-content">
              <h2 className="signup-title" style={{ color: 'white' }}>Become a VAYA Partner</h2>
              <p className="signup-desc" style={{ color: 'white' }}>
                Own a two-wheeler or a mini truck? Onboard your vehicle today, choose your flexible working slots, and start receiving delivery requests instantly.
              </p>
            </div>
            <div>
              <a href="#register" className="btn-secondary" style={{ borderColor: 'white', color: 'white' }}>
                Join as Driver
              </a>
            </div>
          </div>
        </section>

        {/* Cities Section */}
        <section className="section" id="cities" style={{ textAlign: 'center' }}>
          <div className="section-label">NETWORK COVERAGE</div>
          <h2 className="section-title" style={{ marginBottom: '16px' }}>Active Municipal Areas</h2>
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: '8px', padding: '12px 24px', backgroundColor: 'white', borderRadius: '9999px', border: '1px solid var(--fog)' }}>
            <MapPin size={18} style={{ color: 'var(--primary)' }} />
            <span style={{ fontWeight: 'bold', fontSize: '15px' }}>Bhubaneswar, Odisha</span>
          </div>
        </section>
      </main>

      {/* Footer Grid */}
      <footer>
        <div className="footer-container">
          <div className="footer-brand">
            <VayaLogo size={36} color="white" />
            <p className="footer-tagline">
              Your vehicle. At your address. In minutes.
            </p>
          </div>

          <div className="footer-column">
            <h4>SERVICES</h4>
            <ul>
              <li><a href="#business">VAYA Business</a></li>
              <li><a href="#drivers">Driver Partner Program</a></li>
              <li><a href="#vehicles">Vehicle Rates</a></li>
            </ul>
          </div>

          <div className="footer-column">
            <h4>COMPANY</h4>
            <ul>
              <li><a href="#how-it-works">How it Works</a></li>
              <li><a href="#cities">Cities Served</a></li>
              <li><a href="mailto:support@vaya.in">Support Center</a></li>
            </ul>
          </div>

          <div className="footer-column">
            <h4>LEGAL</h4>
            <ul>
              <li><a href="/privacy.html">Privacy Policy</a></li>
              <li><a href="#terms">Terms of Service</a></li>
            </ul>
          </div>
        </div>

        <div className="footer-bottom">
          <span>&copy; {new Date().getFullYear()} VAYA Logistics Network. All rights reserved.</span>
          <span>Designed for premium intra-city freight operations.</span>
        </div>
      </footer>

    </div>
  );
}
