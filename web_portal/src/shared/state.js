import { LANDMARKS } from './mapData';

// Initial Mock Drivers in case server isn't loaded yet
const INITIAL_DRIVERS = [
  {
    id: 'driver-1',
    name: 'Ramesh Kumar',
    phone: '9876543210',
    vehicleType: 'bike',
    vehicleReg: 'OD-02-AX-1234',
    weightCapacity: 20,
    status: 'offline',
    lat: 20.2720,
    lng: 85.8420,
  },
  {
    id: 'driver-2',
    name: 'Suresh Mohanty',
    phone: '9937123456',
    vehicleType: 'mini_truck',
    vehicleReg: 'OD-33-B-5678',
    weightCapacity: 500,
    status: 'offline',
    lat: 20.3390,
    lng: 85.8170,
  },
  {
    id: 'driver-3',
    name: 'Debashish Nayak',
    phone: '9437890123',
    vehicleType: 'large_truck',
    vehicleReg: 'OD-02-C-9012',
    weightCapacity: 2000,
    status: 'offline',
    lat: 20.2580,
    lng: 85.7760,
  }
];

// Client-side profile persistence helpers for offline fallback
const getStoredCustomerProfiles = () => {
  try {
    const raw = localStorage.getItem('sim_customer_profiles');
    return raw ? JSON.parse(raw) : {};
  } catch (e) {
    return {};
  }
};

const saveStoredCustomerProfile = (phone, name) => {
  try {
    const current = getStoredCustomerProfiles();
    current[phone] = { phone, name };
    localStorage.setItem('sim_customer_profiles', JSON.stringify(current));
  } catch (e) {
    console.error('Failed to save to local customer cache:', e);
  }
};

const getStoredDriverProfiles = () => {
  try {
    const raw = localStorage.getItem('sim_driver_profiles');
    return raw ? JSON.parse(raw) : {};
  } catch (e) {
    return {};
  }
};

const saveStoredDriverProfile = (driverId, name, phone, vehicleType, vehicleReg, weightCapacity) => {
  try {
    const current = getStoredDriverProfiles();
    current[phone] = { id: driverId, name, phone, vehicleType, vehicleReg, weightCapacity };
    localStorage.setItem('sim_driver_profiles', JSON.stringify(current));
  } catch (e) {
    console.error('Failed to save to local driver cache:', e);
  }
};

// Retrieve stored state or fall back to default
const getStoredState = () => {
  try {
    const raw = localStorage.getItem('sim_platform_state');
    if (raw) {
      const parsed = JSON.parse(raw);
      const drivers = parsed.drivers || [...INITIAL_DRIVERS];
      // Ensure all INITIAL_DRIVERS are restored if not present
      INITIAL_DRIVERS.forEach(initD => {
        if (!drivers.some(d => d.id === initD.id)) {
          drivers.push(initD);
        }
      });
      return {
        drivers,
        bookings: parsed.bookings || [],
        customers: parsed.customers || []
      };
    }
  } catch (e) {
    console.error('Failed to load stored platform state:', e);
  }
  return {
    drivers: [...INITIAL_DRIVERS],
    bookings: [],
    customers: []
  };
};

let localCache = getStoredState();

const saveLocalCache = () => {
  try {
    localStorage.setItem('sim_platform_state', JSON.stringify(localCache));
  } catch (e) {
    console.error('Failed to save platform state to localStorage:', e);
  }
};

// Always ensure drivers/bookings are arrays to prevent component crashes
const safeState = (raw) => {
  const incomingDrivers = Array.isArray(raw?.drivers) ? raw.drivers : [];
  // Merge incoming remote drivers with local cache (preserving registered offline drivers)
  const mergedDrivers = [...localCache.drivers];
  incomingDrivers.forEach(remoteD => {
    const idx = mergedDrivers.findIndex(d => d.id === remoteD.id);
    if (idx !== -1) {
      mergedDrivers[idx] = { ...mergedDrivers[idx], ...remoteD };
    } else {
      mergedDrivers.push(remoteD);
    }
  });

  return {
    drivers: mergedDrivers,
    bookings: Array.isArray(raw?.bookings) ? raw.bookings : [],
    customers: Array.isArray(raw?.customers) ? raw.customers : (raw?.customers || [])
  };
};

const listeners = new Set();

export const subscribeToState = (callback) => {
  listeners.add(callback);
  // Send the current cached state immediately
  callback(localCache);
  return () => listeners.delete(callback);
};

export const notifyStateChange = () => {
  listeners.forEach((callback) => callback(localCache));
};

export const loadState = () => {
  return localCache;
};

// Seed initial state from REST API
const fetchInitialState = async () => {
  try {
    const res = await fetch('/api/state');
    if (res.ok) {
      const data = await res.json();
      localCache = safeState(data);
      saveLocalCache();
      notifyStateChange();
    }
  } catch (err) {
    console.warn('Failed to fetch initial state from API, using defaults:', err);
  }
};

fetchInitialState();

// Setup WebSocket for live updates
let ws = null;
let reconnectTimeout = null;

const connectWebSocket = () => {
  const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${wsProtocol}//${window.location.host}/ws`;

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    console.log('🔌 Connected to Goods Delivery backend WebSocket.');
    if (reconnectTimeout) {
      clearTimeout(reconnectTimeout);
      reconnectTimeout = null;
    }
  };

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data.type === 'STATE_UPDATED' && data.payload) {
        localCache = safeState(data.payload);
        saveLocalCache();
        notifyStateChange();
      }
    } catch (err) {
      console.error('Error parsing WebSocket update:', err);
    }
  };

  ws.onclose = () => {
    console.warn('🔌 WebSocket disconnected. Retrying in 3 seconds...');
    reconnectTimeout = setTimeout(connectWebSocket, 3000);
  };

  ws.onerror = (err) => {
    console.error('WebSocket connection error:', err);
    ws.close();
  };
};

if (typeof window !== 'undefined') {
  connectWebSocket();
}

// REST actions sending updates to backend API
export const updateDriverOnlineStatus = (driverId, status, name = '', phone = '', vehicleType = 'bike', vehicleReg = '', weightCapacity = 20) => {
  // Optimistic client update
  let driver = localCache.drivers.find(d => d.id === driverId);
  if (!driver) {
    driver = { id: driverId, lat: 20.2720, lng: 85.8420 };
    localCache.drivers.push(driver);
  }
  driver.status = status;
  if (name) driver.name = name;
  if (phone) driver.phone = phone;
  if (vehicleType) driver.vehicleType = vehicleType;
  if (vehicleReg) driver.vehicleReg = vehicleReg;
  if (weightCapacity) driver.weightCapacity = weightCapacity;

  // Persist profile in persistent local cache
  if (phone) {
    saveStoredDriverProfile(driverId, name, phone, vehicleType, vehicleReg, weightCapacity);
  }

  saveLocalCache();
  notifyStateChange();

  fetch('/api/driver/status', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: driverId, status, name, phone, vehicleType, vehicleReg, weightCapacity })
  }).catch(err => console.error('Error updating driver status:', err));
};

export const updateDriverPosition = (driverId, lat, lng) => {
  // Optimistic client update
  const driver = localCache.drivers.find(d => d.id === driverId);
  if (driver) {
    driver.lat = parseFloat(lat);
    driver.lng = parseFloat(lng);
    saveLocalCache();
    notifyStateChange();
  }

  fetch('/api/driver/position', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: driverId, lat, lng })
  }).catch(err => console.error('Error updating driver position:', err));
};

export const createBooking = (bookingData) => {
  const bookingId = bookingData.id || 'booking-' + Date.now();
  const newBooking = {
    id: bookingId,
    status: 'pending',
    createdAt: new Date().toISOString(),
    ...bookingData
  };

  // Optimistic client update
  localCache.bookings.push(newBooking);
  saveLocalCache();
  notifyStateChange();

  fetch('/api/booking', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(newBooking)
  }).catch(err => console.error('Error creating booking:', err));
};

export const acceptBooking = (bookingId, driverId) => {
  // Optimistic client update
  const booking = localCache.bookings.find(b => b.id === bookingId);
  if (booking) {
    booking.status = 'accepted';
    booking.driverId = driverId;
  }
  const driver = localCache.drivers.find(d => d.id === driverId);
  if (driver) {
    driver.status = 'busy';
  }
  saveLocalCache();
  notifyStateChange();

  fetch('/api/booking/accept', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bookingId, driverId })
  }).catch(err => console.error('Error accepting booking:', err));
  return true;
};

export const updateBookingStatus = (bookingId, status) => {
  // Optimistic client update
  const booking = localCache.bookings.find(b => b.id === bookingId);
  if (booking) {
    booking.status = status;
    if (status === 'completed' || status === 'cancelled') {
      const driver = localCache.drivers.find(d => d.id === booking.driverId);
      if (driver) {
        driver.status = 'online';
      }
    }
  }
  saveLocalCache();
  notifyStateChange();

  fetch('/api/booking/status', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bookingId, status })
  }).catch(err => console.error('Error updating booking status:', err));
  return true;
};

export const updateCustomerLiveLocation = (bookingId, lat, lng) => {
  // Optimistic client update
  const booking = localCache.bookings.find(b => b.id === bookingId);
  if (booking) {
    booking.customerLat = lat;
    booking.customerLng = lng;
    saveLocalCache();
    notifyStateChange();
  }

  fetch('/api/booking/customer-location', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bookingId, lat, lng })
  }).catch(err => console.error('Error updating customer live location:', err));
  return true;
};

export const checkCustomerProfile = async (phone) => {
  try {
    const res = await fetch(`/api/customer/${phone}`);
    if (res.ok) {
      const data = await res.json();
      if (data.exists && data.customer) {
        saveStoredCustomerProfile(phone, data.customer.name);
        return data;
      }
    }
  } catch (err) {
    console.error('Error checking customer profile from API:', err);
  }

  // Fallback to local storage persistent profiles
  const profiles = getStoredCustomerProfiles();
  if (profiles[phone]) {
    return { exists: true, customer: profiles[phone] };
  }
  return { exists: false };
};

export const checkDriverProfile = async (phone) => {
  try {
    const res = await fetch(`/api/driver/by-phone/${phone}`);
    if (res.ok) {
      const data = await res.json();
      if (data.exists && data.driver) {
        const d = data.driver;
        saveStoredDriverProfile(d.id, d.name, d.phone, d.vehicleType, d.vehicleReg, d.weightCapacity);
        return data;
      }
    }
  } catch (err) {
    console.error('Error checking driver profile from API:', err);
  }

  // Fallback to local storage persistent profiles
  const profiles = getStoredDriverProfiles();
  if (profiles[phone]) {
    return { exists: true, driver: profiles[phone] };
  }
  return { exists: false };
};

export const saveCustomerProfile = async (phone, name) => {
  // Optimistic client save
  saveStoredCustomerProfile(phone, name);

  if (!localCache.customers) localCache.customers = [];
  const existingCust = localCache.customers.find(c => c.phone === phone);
  if (existingCust) {
    existingCust.name = name;
  } else {
    localCache.customers.push({ phone, name });
  }
  saveLocalCache();
  notifyStateChange();

  try {
    const res = await fetch('/api/customer', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ phone, name })
    });
    if (res.ok) {
      return await res.json();
    }
  } catch (err) {
    console.error('Error saving customer profile via API:', err);
  }
  return { success: true };
};

export const resetPlatformState = () => {
  localCache = {
    drivers: [...INITIAL_DRIVERS],
    bookings: [],
    customers: []
  };
  saveLocalCache();
  notifyStateChange();

  fetch('/api/state/reset', {
    method: 'POST'
  }).catch(err => console.error('Error resetting platform state:', err));
  return localCache;
};

export const timeoutExpiredBookings = () => {
  // Handled automatically on the server side
  return 0;
};
