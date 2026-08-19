import { useState, useEffect } from 'react';
import LeafletMap from './LeafletMap';
import VayaLoader from './VayaLoader';
import { 
  Users, 
  Truck, 
  Map, 
  DollarSign, 
  Calendar, 
  Clock,
  FileText,
  CheckCircle,
  AlertCircle
} from 'lucide-react';

const getApiBaseUrl = () => {
  if (typeof window !== 'undefined' && (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1')) {
    return 'http://localhost:5001';
  }
  return import.meta.env.VITE_API_BASE_URL || (import.meta.env.DEV ? 'http://localhost:5001' : 'https://vaya-backend-275777907648.us-central1.run.app');
};

const getWsBaseUrl = () => {
  if (typeof window !== 'undefined' && (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1')) {
    return 'ws://localhost:5001';
  }
  return import.meta.env.VITE_WS_BASE_URL || (import.meta.env.DEV ? 'ws://localhost:5001' : 'wss://vaya-backend-275777907648.us-central1.run.app');
};

const apiBaseUrl = getApiBaseUrl();
const wsBaseUrl = getWsBaseUrl();

const defaultPricing = [
  { vehicle_type: 'bike', base_price: 40, base_distance: 2, per_km_price: 10, free_wait_minutes_pickup: 10, free_wait_minutes_dropoff: 10, wait_charge_per_minute: 2, description: 'Quick deliveries up to 20 kg' },
  { vehicle_type: 'three_wheeler', base_price: 120, base_distance: 3, per_km_price: 18, free_wait_minutes_pickup: 10, free_wait_minutes_dropoff: 10, wait_charge_per_minute: 2, description: 'Medium cargo up to 150 kg' },
  { vehicle_type: 'ace', base_price: 250, base_distance: 5, per_km_price: 25, free_wait_minutes_pickup: 10, free_wait_minutes_dropoff: 10, wait_charge_per_minute: 2, description: 'Heavy cargo up to 600 kg' },
  { vehicle_type: 'truck', base_price: 500, base_distance: 5, per_km_price: 35, free_wait_minutes_pickup: 10, free_wait_minutes_dropoff: 10, wait_charge_per_minute: 2, description: 'Very heavy cargo up to 2,000 kg' },
];

const loadCachedPricing = () => {
  try {
    const cached = localStorage.getItem('vaya_pricing_config');
    if (cached) {
      const parsed = JSON.parse(cached);
      if (Array.isArray(parsed) && parsed.length > 0) return parsed;
    }
  } catch (e) {
    console.error('Error loading cached pricing:', e);
  }
  return defaultPricing;
};

export default function AdminDashboard({ adminUser }) {
  const [activeTab, setActiveTab] = useState('orders'); // orders, drivers, audit, pricing
  const [metrics, setMetrics] = useState({
    totalBookings: 0,
    activeDeliveries: 0,
    completedEarnings: 0,
    driversOnline: 0,
    driversBusy: 0,
    driversOffline: 0
  });
  const [bookings, setBookings] = useState([]);
  const [drivers, setDrivers] = useState([]);
  const [auditLogs, setAuditLogs] = useState([]);
  const [pricingConfig, setPricingConfig] = useState(loadCachedPricing);
  const [isLoading, setIsLoading] = useState(true);

  // Live clock
  const [clock, setClock] = useState(() => {
    const d = new Date();
    return d.getHours().toString().padStart(2,'0') + ':' + d.getMinutes().toString().padStart(2,'0');
  });

  useEffect(() => {
    const tick = setInterval(() => {
      const d = new Date();
      setClock(d.getHours().toString().padStart(2,'0') + ':' + d.getMinutes().toString().padStart(2,'0'));
    }, 30000);
    return () => clearInterval(tick);
  }, []);

  const fetchData = async () => {
    try {
      const token = await adminUser.getIdToken();
      const headers = { 'Authorization': `Bearer ${token}` };

      const fetchJson = async (url, opts) => {
        try {
          const res = await fetch(url, opts);
          if (res.ok) {
            return await res.json();
          }
          console.warn(`API returned non-OK status: ${res.status} for ${url}`);
        } catch (err) {
          console.error(`Failed fetching ${url}:`, err);
        }
        return null;
      };

      const [metricsData, bookingsData, auditData] = await Promise.all([
        fetchJson(`${apiBaseUrl}/api/admin/dashboard`, { headers }),
        fetchJson(`${apiBaseUrl}/api/admin/bookings`, { headers }),
        fetchJson(`${apiBaseUrl}/api/admin/audit-log`, { headers }),
      ]);
      // Try /api/admin/partners first; fall back to /api/admin/drivers if null
      const driversData =
        (await fetchJson(`${apiBaseUrl}/api/admin/partners`, { headers })) ??
        (await fetchJson(`${apiBaseUrl}/api/admin/drivers`, { headers }));

      const pricingData = await fetchJson(`${apiBaseUrl}/api/health/pricing-config`);

      if (metricsData) setMetrics(metricsData.metrics || {});
      if (bookingsData) setBookings(bookingsData.bookings || []);
      if (driversData) setDrivers(driversData.partners || driversData.drivers || []);
      if (auditData) setAuditLogs(auditData.logs || []);

      const list = pricingData?.pricing || (Array.isArray(pricingData) ? pricingData : null);
      if (list && list.length > 0) {
        const formatted = list.map(item => ({
          vehicle_type: item.vehicle_type,
          base_price: Number(item.base_price),
          base_distance: Number(item.base_distance),
          per_km_price: Number(item.per_km_price),
          free_wait_minutes_pickup: Number(item.free_wait_minutes_pickup ?? 10),
          free_wait_minutes_dropoff: Number(item.free_wait_minutes_dropoff ?? 10),
          wait_charge_per_minute: Number(item.wait_charge_per_minute ?? 2.00),
          description: item.description || ''
        }));
        setPricingConfig(formatted);
        try {
          localStorage.setItem('vaya_pricing_config', JSON.stringify(formatted));
        // eslint-disable-next-line no-empty
        } catch (e) {}
      }
    } catch (e) {
      console.error('Failed to load dashboard data:', e);
    } finally {
      setIsLoading(false);
    }
  };

  const handleUpdatePricing = async (e) => {
    e.preventDefault();
    if (!window.confirm('Save these live delivery rates & waiting charges?')) return;
    try {
      const token = await adminUser.getIdToken();
      const payload = pricingConfig.map(p => ({
        vehicle_type: p.vehicle_type,
        base_price: parseFloat(p.base_price) || 0,
        base_distance: parseFloat(p.base_distance) || 0,
        per_km_price: parseFloat(p.per_km_price) || 0,
        free_wait_minutes_pickup: parseInt(p.free_wait_minutes_pickup) || 0,
        free_wait_minutes_dropoff: parseInt(p.free_wait_minutes_dropoff) || 0,
        wait_charge_per_minute: parseFloat(p.wait_charge_per_minute) || 0
      }));

      // Instantly save to local state and localStorage for instant UI feedback
      setPricingConfig(payload);
      try {
        localStorage.setItem('vaya_pricing_config', JSON.stringify(payload));
      // eslint-disable-next-line no-empty
      } catch (err) {}

      const res = await fetch(`${apiBaseUrl}/api/admin/pricing-config`, {
        method: 'PUT',
        headers: { 
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}` 
        },
        body: JSON.stringify({ pricing: payload })
      });

      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        const rawList = data.pricing || payload;
        const formatted = rawList.map(item => ({
          vehicle_type: item.vehicle_type,
          base_price: Number(item.base_price),
          base_distance: Number(item.base_distance),
          per_km_price: Number(item.per_km_price),
          free_wait_minutes_pickup: Number(item.free_wait_minutes_pickup ?? 10),
          free_wait_minutes_dropoff: Number(item.free_wait_minutes_dropoff ?? 10),
          wait_charge_per_minute: Number(item.wait_charge_per_minute ?? 2.00),
          description: item.description || ''
        }));
        setPricingConfig(formatted);
        try {
          localStorage.setItem('vaya_pricing_config', JSON.stringify(formatted));
        // eslint-disable-next-line no-empty
        } catch (e) {}
        alert('Pricing rates updated live successfully!');
      } else if (res.status === 429) {
        alert('Rate limit exceeded on backend. Your local rates are saved and will sync automatically shortly.');
      } else {
        const errData = await res.json().catch(() => ({}));
        alert(`Failed to update pricing on server: ${errData.error || 'Unknown error'}`);
      }
    } catch (e) {
      console.error('Error updating pricing:', e);
      alert('Error updating pricing configuration.');
    }
  };

  // Recalculate driver metrics whenever drivers list updates
  useEffect(() => {
    if (!drivers || drivers.length === 0) return;
    const online = drivers.filter(d => d.status === 'online').length;
    const busy = drivers.filter(d => d.status === 'busy').length;
    const offline = drivers.filter(d => !d.status || d.status === 'offline').length;
    setMetrics(prev => ({
      ...prev,
      driversOnline: online,
      driversBusy: busy,
      driversOffline: offline
    }));
  }, [drivers]);

  useEffect(() => {
    fetchData();
    
    // Setup WS listener
    let ws;
    const connectWs = async () => {
      try {
        const token = await adminUser.getIdToken();
        ws = new WebSocket(`${wsBaseUrl}/ws?token=${token}`);

        ws.onmessage = (event) => {
          const data = JSON.parse(event.data);
          
          if (data.type === 'driver_position') {
            setDrivers(prev => prev.map(d => d.id === data.driverId ? { ...d, lat: data.lat, lng: data.lng, status: data.status || d.status } : d));
          } else if (data.type === 'driver_status') {
            setDrivers(prev => {
              const exists = prev.some(d => d.id === data.driverId);
              if (exists) {
                return prev.map(d => d.id === data.driverId ? { ...d, status: data.status, ...(data.driver || {}) } : d);
              } else if (data.driver) {
                return [data.driver, ...prev];
              }
              return prev;
            });
          } else if (data.type === 'booking_created') {
            setBookings(prev => [data.booking, ...prev]);
          } else if (data.type === 'booking_accepted' || data.type === 'booking_transit' || data.type === 'booking_status') {
            setBookings(prev => prev.map(b => b.id === (data.booking?.id || data.bookingId) ? { ...b, ...data.booking } : b));
          } else if (data.type === 'pricing_updated' && data.pricing) {
            const formatted = data.pricing.map(item => ({
              vehicle_type: item.vehicle_type,
              base_price: Number(item.base_price),
              base_distance: Number(item.base_distance),
              per_km_price: Number(item.per_km_price),
              free_wait_minutes_pickup: Number(item.free_wait_minutes_pickup ?? 10),
              free_wait_minutes_dropoff: Number(item.free_wait_minutes_dropoff ?? 10),
              wait_charge_per_minute: Number(item.wait_charge_per_minute ?? 2.00),
              description: item.description || ''
            }));
            setPricingConfig(formatted);
            try {
              localStorage.setItem('vaya_pricing_config', JSON.stringify(formatted));
            // eslint-disable-next-line no-empty
            } catch (e) {}
          }
        };

        ws.onclose = () => {
          setTimeout(connectWs, 3000); // Reconnect
        };
      } catch (err) {
        console.error('WebSocket connection setup failed:', err);
      }
    };

    connectWs();
    return () => ws && ws.close();
  }, [adminUser]);

  const handleApproveDriver = async (driverId) => {
    if (!window.confirm('Are you sure you want to approve this driver partner?')) return;
    try {
      const token = await adminUser.getIdToken();
      const res = await fetch(`${apiBaseUrl}/api/admin/partners/${driverId}/approve`, {
        method: 'PUT',
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (res.ok) {
        fetchData();
      } else {
        alert('Failed to approve driver.');
      }
    } catch (e) {
      console.error('Error approving driver:', e);
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', backgroundColor: '#f8fafc' }}>
      
      {/* Dashboard Top bar */}
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '16px 24px', background: '#fff', borderBottom: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', zIndex: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <div style={{ padding: '8px', borderRadius: '8px', backgroundColor: 'var(--primary-light)' }}>
            <Truck size={24} style={{ color: 'var(--primary)' }} />
          </div>
          <div>
            <h1 style={{ fontFamily: 'var(--font-display)', fontWeight: 800, fontSize: '20px', color: 'var(--text-heading)' }}>
              VAYA Control Center
            </h1>
            <p style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>Vehicle at Your Address Operations Hub</p>
          </div>
        </div>

        <div style={{ display: 'flex', gap: '12px', alignItems: 'center' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '6px', fontSize: '12px', color: 'var(--text-secondary)', background: 'var(--bg-primary)', padding: '6px 12px', borderRadius: '8px', border: '1px solid var(--border-color)' }}>
            <Clock size={14} style={{ color: 'var(--primary)' }} />
            <span style={{ fontWeight: '700', fontVariantNumeric: 'tabular-nums' }}>{clock}</span>
          </div>
        </div>
      </header>

      {/* Main Stats Widgets */}
      <section style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '16px', padding: '20px 24px' }}>
        <div style={{ background: '#fff', padding: '16px', borderRadius: '12px', border: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', display: 'flex', alignItems: 'center', gap: '16px' }}>
          <div style={{ padding: '12px', borderRadius: '10px', backgroundColor: 'var(--primary-light)' }}>
            <Calendar size={22} style={{ color: 'var(--primary)' }} />
          </div>
          <div>
            <span style={{ fontSize: '11px', fontWeight: 'bold', color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Total Bookings</span>
            <h3 style={{ fontSize: '22px', fontWeight: 800, color: 'var(--text-heading)', marginTop: '2px' }}>{metrics.totalBookings}</h3>
          </div>
        </div>

        <div style={{ background: '#fff', padding: '16px', borderRadius: '12px', border: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', display: 'flex', alignItems: 'center', gap: '16px' }}>
          <div style={{ padding: '12px', borderRadius: '10px', backgroundColor: 'hsl(200, 95%, 96%)' }}>
            <Clock size={22} style={{ color: 'var(--info)' }} />
          </div>
          <div>
            <span style={{ fontSize: '11px', fontWeight: 'bold', color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Active Deliveries</span>
            <h3 style={{ fontSize: '22px', fontWeight: 800, color: 'var(--text-heading)', marginTop: '2px' }}>{metrics.activeDeliveries}</h3>
          </div>
        </div>

        <div style={{ background: '#fff', padding: '16px', borderRadius: '12px', border: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', display: 'flex', alignItems: 'center', gap: '16px' }}>
          <div style={{ padding: '12px', borderRadius: '10px', backgroundColor: 'var(--success-light)' }}>
            <DollarSign size={22} style={{ color: 'var(--success)' }} />
          </div>
          <div>
            <span style={{ fontSize: '11px', fontWeight: 'bold', color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Completed Earnings</span>
            <h3 style={{ fontSize: '22px', fontWeight: 800, color: 'var(--text-heading)', marginTop: '2px' }}>₹{metrics.completedEarnings}</h3>
          </div>
        </div>

        <div style={{ background: '#fff', padding: '16px', borderRadius: '12px', border: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', display: 'flex', alignItems: 'center', gap: '16px' }}>
          <div style={{ padding: '12px', borderRadius: '10px', backgroundColor: 'hsl(38, 92%, 96%)' }}>
            <Users size={22} style={{ color: 'var(--warning)' }} />
          </div>
          <div>
            <span style={{ fontSize: '11px', fontWeight: 'bold', color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Driver Partner Status</span>
            <div style={{ display: 'flex', gap: '8px', alignItems: 'baseline', marginTop: '2px' }}>
              <h3 style={{ fontSize: '22px', fontWeight: 800, color: 'var(--text-heading)' }}>
                {metrics.driversOnline + metrics.driversBusy}
              </h3>
              <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>
                ({metrics.driversOnline} Free, {metrics.driversBusy} Busy, {metrics.driversOffline} Off)
              </span>
            </div>
          </div>
        </div>
      </section>

      {/* Main Workspace */}
      <div style={{ flex: 1, display: 'flex', padding: '0 24px 24px', gap: '20px', minHeight: 0 }}>
        
        {/* Left Side: Tables */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', background: '#fff', borderRadius: '12px', border: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', overflow: 'hidden' }}>
          
          {/* Tabs bar */}
          <div style={{ display: 'flex', borderBottom: '1px solid var(--border-color)', background: '#f8fafc', padding: '12px 16px 0', gap: '8px' }}>
            <button 
              onClick={() => setActiveTab('orders')}
              className={`btn ${activeTab === 'orders' ? 'btn-primary' : 'btn-secondary'}`}
              style={{ borderRadius: '8px 8px 0 0', borderBottom: 'none', padding: '10px 18px', fontSize: '13px' }}
            >
              <Truck size={15} />
              <span>Deliveries</span>
            </button>
            <button 
              onClick={() => setActiveTab('drivers')}
              className={`btn ${activeTab === 'drivers' ? 'btn-primary' : 'btn-secondary'}`}
              style={{ borderRadius: '8px 8px 0 0', borderBottom: 'none', padding: '10px 18px', fontSize: '13px' }}
            >
              <Users size={15} />
              <span>Driver Partners</span>
            </button>
            <button 
              onClick={() => setActiveTab('audit')}
              className={`btn ${activeTab === 'audit' ? 'btn-primary' : 'btn-secondary'}`}
              style={{ borderRadius: '8px 8px 0 0', borderBottom: 'none', padding: '10px 18px', fontSize: '13px' }}
            >
              <FileText size={15} />
              <span>Audit Logs</span>
            </button>
            <button 
              onClick={() => setActiveTab('pricing')}
              className={`btn ${activeTab === 'pricing' ? 'btn-primary' : 'btn-secondary'}`}
              style={{ borderRadius: '8px 8px 0 0', borderBottom: 'none', padding: '10px 18px', fontSize: '13px' }}
            >
              <DollarSign size={15} />
              <span>Pricing Manager</span>
            </button>
          </div>

          {/* Table Container */}
          <div style={{ flex: 1, overflowY: 'auto', padding: '16px' }}>
            {isLoading ? (
              <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', height: '100%', minHeight: '240px' }}>
                <VayaLoader
                  variant="section"
                  size="md"
                  message="Loading dashboard data..."
                  accessibleLabel="Loading dashboard metrics and records"
                />
              </div>
            ) : (
              <>
                {/* Orders Tab */}
                {activeTab === 'orders' && (
                  <table style={{ width: '100%', borderCollapse: 'collapse', textAlign: 'left', fontSize: '13px' }}>
                    <thead>
                      <tr style={{ borderBottom: '2px solid var(--border-color)', color: 'var(--text-secondary)', fontWeight: 'bold' }}>
                        <th style={{ padding: '12px 8px' }}>Order ID</th>
                        <th style={{ padding: '12px 8px' }}>Route Details</th>
                        <th style={{ padding: '12px 8px' }}>Vehicle Class</th>
                        <th style={{ padding: '12px 8px' }}>Weight</th>
                        <th style={{ padding: '12px 8px' }}>Cost</th>
                        <th style={{ padding: '12px 8px' }}>Driver</th>
                        <th style={{ padding: '12px 8px' }}>Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {bookings.length === 0 ? (
                        <tr>
                          <td colSpan="7" style={{ textAlign: 'center', padding: '32px', color: 'var(--text-secondary)' }}>No delivery orders registered.</td>
                        </tr>
                      ) : (
                        bookings.map(b => (
                          <tr key={b.id} style={{ borderBottom: '1px solid var(--border-color)' }}>
                            <td style={{ padding: '12px 8px', fontFamily: 'monospace', fontWeight: 'bold' }}>{b.id.substring(0, 8)}</td>
                            <td style={{ padding: '12px 8px' }}>
                              <div style={{ fontWeight: 600 }}>{b.pickup_name}</div>
                              <div style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>➔ {b.dropoff_name}</div>
                            </td>
                            <td style={{ padding: '12px 8px', textTransform: 'capitalize' }}>{b.vehicle_type}</td>
                            <td style={{ padding: '12px 8px' }}>{b.weight} kg</td>
                            <td style={{ padding: '12px 8px', fontWeight: 'bold' }}>₹{b.estimated_cost}</td>
                            <td style={{ padding: '12px 8px' }}>
                              {b.driver_name ? (
                                <div>
                                  <div style={{ fontWeight: 500 }}>{b.driver_name}</div>
                                  <div style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>{b.driver_plate}</div>
                                </div>
                              ) : (
                                <span style={{ color: 'var(--text-secondary)', fontStyle: 'italic' }}>Unassigned</span>
                              )}
                            </td>
                            <td style={{ padding: '12px 8px' }}>
                              <span className={`badge badge-${b.status === 'completed' ? 'success' : b.status === 'cancelled' || b.status === 'expired' ? 'error' : 'warning'}`}>
                                {b.status.replace('_', ' ')}
                              </span>
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                )}

                {/* Drivers Tab */}
                {activeTab === 'drivers' && (
                  <table style={{ width: '100%', borderCollapse: 'collapse', textAlign: 'left', fontSize: '13px' }}>
                    <thead>
                      <tr style={{ borderBottom: '2px solid var(--border-color)', color: 'var(--text-secondary)', fontWeight: 'bold' }}>
                        <th style={{ padding: '12px 8px' }}>Driver</th>
                        <th style={{ padding: '12px 8px' }}>Phone Number</th>
                        <th style={{ padding: '12px 8px' }}>Rating</th>
                        <th style={{ padding: '12px 8px' }}>Vehicle Info</th>
                        <th style={{ padding: '12px 8px' }}>Capacity</th>
                        <th style={{ padding: '12px 8px' }}>Live Status</th>
                        <th style={{ padding: '12px 8px' }}>Approval Status</th>
                        <th style={{ padding: '12px 8px' }}>Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      {drivers.length === 0 ? (
                        <tr>
                          <td colSpan="8" style={{ textAlign: 'center', padding: '32px', color: 'var(--text-secondary)' }}>No driver partners registered.</td>
                        </tr>
                      ) : (
                        drivers.map(d => (
                          <tr key={d.id} style={{ borderBottom: '1px solid var(--border-color)' }}>
                            <td style={{ padding: '12px 8px', fontWeight: 'bold' }}>{d.name}</td>
                            <td style={{ padding: '12px 8px' }}>{d.phone}</td>
                            <td style={{ padding: '12px 8px' }}>
                              <div style={{ display: 'inline-flex', alignItems: 'center', gap: '4px', fontWeight: 'bold', color: '#ca8a04' }}>
                                ★ {d.rating_avg ? parseFloat(d.rating_avg).toFixed(1) : '5.0'}
                                <span style={{ fontSize: '11px', color: 'var(--text-secondary)', fontWeight: 'normal' }}>({d.rating_count || 0})</span>
                              </div>
                            </td>
                            <td style={{ padding: '12px 8px' }}>
                              <div style={{ textTransform: 'capitalize', fontWeight: 500 }}>{d.vehicle_type}</div>
                              <div style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>{d.vehicle_reg}</div>
                            </td>
                            <td style={{ padding: '12px 8px' }}>{d.weight_capacity} kg</td>
                            <td style={{ padding: '12px 8px' }}>
                              <span style={{ 
                                display: 'inline-flex', 
                                alignItems: 'center', 
                                gap: '6px', 
                                padding: '4px 10px', 
                                borderRadius: '12px', 
                                fontSize: '12px', 
                                fontWeight: '600',
                                textTransform: 'capitalize',
                                backgroundColor: d.status === 'online' ? '#dcfce7' : d.status === 'busy' ? '#fef9c3' : '#f1f5f9',
                                color: d.status === 'online' ? '#15803d' : d.status === 'busy' ? '#a16207' : '#64748b',
                                border: `1px solid ${d.status === 'online' ? '#bbf7d0' : d.status === 'busy' ? '#fef08a' : '#e2e8f0'}`
                              }}>
                                <span style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: d.status === 'online' ? '#16a34a' : d.status === 'busy' ? '#eab308' : '#94a3b8' }} />
                                {d.status || 'offline'}
                              </span>
                            </td>
                            <td style={{ padding: '12px 8px' }}>
                              <span className={`badge ${d.is_approved ? 'badge-success' : 'badge-warning'}`} style={{ display: 'inline-flex', alignItems: 'center', gap: '4px' }}>
                                {d.is_approved ? <CheckCircle size={12} /> : <AlertCircle size={12} />}
                                {d.is_approved ? 'Approved' : 'Pending Review'}
                              </span>
                            </td>
                            <td style={{ padding: '12px 8px' }}>
                              {!d.is_approved && (
                                <button 
                                  className="btn btn-primary"
                                  style={{ padding: '4px 10px', fontSize: '11px' }}
                                  onClick={() => handleApproveDriver(d.id)}
                                >
                                  Approve Partner
                                </button>
                              )}
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                )}

                {/* Audit Logs Tab */}
                {activeTab === 'audit' && (
                  <table style={{ width: '100%', borderCollapse: 'collapse', textAlign: 'left', fontSize: '13px' }}>
                    <thead>
                      <tr style={{ borderBottom: '2px solid var(--border-color)', color: 'var(--text-secondary)', fontWeight: 'bold' }}>
                        <th style={{ padding: '12px 8px' }}>Time</th>
                        <th style={{ padding: '12px 8px' }}>Action</th>
                        <th style={{ padding: '12px 8px' }}>Details</th>
                      </tr>
                    </thead>
                    <tbody>
                      {auditLogs.length === 0 ? (
                        <tr>
                          <td colSpan="3" style={{ textAlign: 'center', padding: '32px', color: 'var(--text-secondary)' }}>Audit logs are clean.</td>
                        </tr>
                      ) : (
                        auditLogs.map(log => (
                          <tr key={log.id} style={{ borderBottom: '1px solid var(--border-color)' }}>
                            <td style={{ padding: '12px 8px', color: 'var(--text-secondary)', whiteSpace: 'nowrap' }}>{new Date(log.created_at).toLocaleString()}</td>
                            <td style={{ padding: '12px 8px', fontWeight: 'bold', textTransform: 'uppercase', fontSize: '11px', color: 'var(--primary)' }}>{log.action.replace('_', ' ')}</td>
                            <td style={{ padding: '12px 8px' }}>{log.details}</td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                )}
                {/* Pricing Manager Tab */}
                {activeTab === 'pricing' && (
                  <form onSubmit={handleUpdatePricing} style={{ maxWidth: '600px', display: 'flex', flexDirection: 'column', gap: '20px' }}>
                    <div>
                      <h3 style={{ fontSize: '15px', fontWeight: 'bold', color: 'var(--text-heading)', marginBottom: '4px' }}>Live Delivery Rates Management</h3>
                      <p style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>Modify the base rates, distance limits, and per-km pricing for all 4 vehicle classes. Changes are applied instantly to customer booking screens.</p>
                    </div>

                    {pricingConfig.map((item, index) => (
                      <div key={item.vehicle_type} style={{ padding: '16px', borderRadius: '8px', border: '1px solid var(--border-color)', background: '#fafafa', display: 'flex', flexDirection: 'column', gap: '12px' }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                          <span style={{ fontWeight: 'bold', textTransform: 'capitalize', color: 'var(--primary)', fontSize: '13px' }}>
                            {item.vehicle_type === 'bike' ? 'Bike' : item.vehicle_type === 'three_wheeler' ? 'Cargo 3-wheeler' : item.vehicle_type === 'ace' ? 'Mini Truck (4-wheeler)' : 'Light Commercial Vehicle (4-wheeler)'}
                          </span>
                          <span style={{ fontSize: '11px', color: 'var(--text-secondary)', fontStyle: 'italic' }}>({item.vehicle_type})</span>
                        </div>

                        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '12px' }}>
                          <div>
                            <label style={{ fontSize: '11px', fontWeight: '600', color: 'var(--text-secondary)', display: 'block', marginBottom: '4px' }}>Base Price (₹)</label>
                            <input 
                              type="number" 
                              value={item.base_price}
                              className="form-input"
                              style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                              onChange={(e) => {
                                const val = e.target.value;
                                setPricingConfig(prev => prev.map((p, i) => i === index ? { ...p, base_price: val === '' ? '' : val } : p));
                              }}
                            />
                          </div>

                          <div>
                            <label style={{ fontSize: '11px', fontWeight: '600', color: 'var(--text-secondary)', display: 'block', marginBottom: '4px' }}>Base Distance (km)</label>
                            <input 
                              type="number" 
                              step="0.1"
                              value={item.base_distance}
                              className="form-input"
                              style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                              onChange={(e) => {
                                const val = e.target.value;
                                setPricingConfig(prev => prev.map((p, i) => i === index ? { ...p, base_distance: val === '' ? '' : val } : p));
                              }}
                            />
                          </div>

                          <div>
                            <label style={{ fontSize: '11px', fontWeight: '600', color: 'var(--text-secondary)', display: 'block', marginBottom: '4px' }}>Per KM Price (₹)</label>
                            <input 
                              type="number" 
                              value={item.per_km_price}
                              className="form-input"
                              style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                              onChange={(e) => {
                                const val = e.target.value;
                                setPricingConfig(prev => prev.map((p, i) => i === index ? { ...p, per_km_price: val === '' ? '' : val } : p));
                              }}
                            />
                          </div>
                        </div>

                        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '12px', marginTop: '4px', paddingTop: '10px', borderTop: '1px dashed #e2e8f0' }}>
                          <div>
                            <label style={{ fontSize: '11px', fontWeight: '600', color: '#92400e', display: 'block', marginBottom: '4px' }}>Free Pickup Wait (mins)</label>
                            <input 
                              type="number" 
                              min="0"
                              value={item.free_wait_minutes_pickup ?? 10}
                              className="form-input"
                              style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                              onChange={(e) => {
                                const val = e.target.value;
                                setPricingConfig(prev => prev.map((p, i) => i === index ? { ...p, free_wait_minutes_pickup: val === '' ? '' : parseInt(val) || 0 } : p));
                              }}
                            />
                          </div>

                          <div>
                            <label style={{ fontSize: '11px', fontWeight: '600', color: '#92400e', display: 'block', marginBottom: '4px' }}>Free Dropoff Wait (mins)</label>
                            <input 
                              type="number" 
                              min="0"
                              value={item.free_wait_minutes_dropoff ?? 10}
                              className="form-input"
                              style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                              onChange={(e) => {
                                const val = e.target.value;
                                setPricingConfig(prev => prev.map((p, i) => i === index ? { ...p, free_wait_minutes_dropoff: val === '' ? '' : parseInt(val) || 0 } : p));
                              }}
                            />
                          </div>

                          <div>
                            <label style={{ fontSize: '11px', fontWeight: '600', color: '#92400e', display: 'block', marginBottom: '4px' }}>Charge / Min (₹)</label>
                            <input 
                              type="number" 
                              step="0.5"
                              min="0"
                              value={item.wait_charge_per_minute ?? 2.0}
                              className="form-input"
                              style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                              onChange={(e) => {
                                const val = e.target.value;
                                setPricingConfig(prev => prev.map((p, i) => i === index ? { ...p, wait_charge_per_minute: val === '' ? '' : parseFloat(val) || 0 } : p));
                              }}
                            />
                          </div>
                        </div>
                      </div>
                    ))}

                    {/* Waiting Time Charges Bulk Update Card */}
                    <div style={{ padding: '16px', borderRadius: '8px', border: '1px solid #fde68a', background: '#fffbeb', display: 'flex', flexDirection: 'column', gap: '12px' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                        <Clock size={16} style={{ color: '#d97706' }} />
                        <span style={{ fontWeight: 'bold', color: '#92400e', fontSize: '13px' }}>
                          Bulk Set Waiting Time Charges (All Vehicles)
                        </span>
                      </div>
                      <p style={{ fontSize: '11px', color: '#b45309', margin: 0 }}>
                        Quickly set uniform free waiting minutes and per-minute charges across all vehicle classes.
                      </p>

                      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '12px' }}>
                        <div>
                          <label style={{ fontSize: '11px', fontWeight: '600', color: '#92400e', display: 'block', marginBottom: '4px' }}>Free Pickup Wait (mins)</label>
                          <input 
                            type="number" 
                            min="0"
                            value={pricingConfig[0]?.free_wait_minutes_pickup ?? 10}
                            className="form-input"
                            style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                            onChange={(e) => {
                              const val = e.target.value;
                              setPricingConfig(prev => prev.map(p => ({ ...p, free_wait_minutes_pickup: val === '' ? '' : parseInt(val) || 0 })));
                            }}
                          />
                        </div>

                        <div>
                          <label style={{ fontSize: '11px', fontWeight: '600', color: '#92400e', display: 'block', marginBottom: '4px' }}>Free Dropoff Wait (mins)</label>
                          <input 
                            type="number" 
                            min="0"
                            value={pricingConfig[0]?.free_wait_minutes_dropoff ?? 10}
                            className="form-input"
                            style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                            onChange={(e) => {
                              const val = e.target.value;
                              setPricingConfig(prev => prev.map(p => ({ ...p, free_wait_minutes_dropoff: val === '' ? '' : parseInt(val) || 0 })));
                            }}
                          />
                        </div>

                        <div>
                          <label style={{ fontSize: '11px', fontWeight: '600', color: '#92400e', display: 'block', marginBottom: '4px' }}>Charge / Minute (₹)</label>
                          <input 
                            type="number" 
                            step="0.5"
                            min="0"
                            value={pricingConfig[0]?.wait_charge_per_minute ?? 2.0}
                            className="form-input"
                            style={{ width: '100%', padding: '8px 12px', fontSize: '13px' }}
                            onChange={(e) => {
                              const val = e.target.value;
                              setPricingConfig(prev => prev.map(p => ({ ...p, wait_charge_per_minute: val === '' ? '' : parseFloat(val) || 0 })));
                            }}
                          />
                        </div>
                      </div>
                    </div>

                    <button type="submit" className="btn btn-primary" style={{ alignSelf: 'flex-start', padding: '10px 20px', fontSize: '13px' }}>
                      Save Live Rates & Waiting Charges
                    </button>
                  </form>
                )}
              </>
            )}
          </div>
        </div>

        {/* Right Side: Map Monitor */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', background: '#fff', borderRadius: '12px', border: '1px solid var(--border-color)', boxShadow: 'var(--shadow-sm)', overflow: 'hidden' }}>
          <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border-color)', background: '#f8fafc', display: 'flex', alignItems: 'center', gap: '8px' }}>
            <Map size={16} style={{ color: 'var(--primary)' }} />
            <span style={{ fontWeight: 'bold', fontSize: '13px', color: 'var(--text-heading)' }}>Operations Map Monitor</span>
          </div>
          <div style={{ flex: 1, position: 'relative' }}>
            <LeafletMap 
              drivers={drivers.filter(d => d.status !== 'offline')}
            />
          </div>
        </div>

      </div>
    </div>
  );
}
