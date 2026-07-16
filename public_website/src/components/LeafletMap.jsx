import { useEffect, useRef, useState } from 'react';
import { setOptions, importLibrary } from '@googlemaps/js-api-loader';
const BHUBANESWAR_CENTER = { lat: 20.2961, lng: 85.8245 };
const DEFAULT_ZOOM = 13;
const GOOGLE_MAPS_API_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY;

export default function LeafletMap({
  pickupLatLng = null,
  dropoffLatLng = null,
  drivers = [],
  selectingMode = null,
  onMapClick = null,
  routeCoords = null,
  height = '100%',
  userLatLng = null,
  customerLiveLatLng = null,
  mapCenter = null,
  followLatLng = null,
}) {
  const mapRef = useRef(null);
  const [mapInstance, setMapInstance] = useState(null);
  const lastFollowPosRef = useRef(null); // tracks last position to avoid redundant pans

  // References to keep track of active map overlays
  const mapOverlayRef = useRef({
    pickupMarker: null,
    dropoffMarker: null,
    userMarker: null,
    customerLiveMarker: null,
    driverMarkers: {},
    polyline: null,
  });

  // Keep latest onMapClick and selectingMode in ref for events
  const clickHandlersRef = useRef({ onMapClick, selectingMode });
  useEffect(() => {
    clickHandlersRef.current = { onMapClick, selectingMode };
  }, [onMapClick, selectingMode]);

  // Initialize Map using the functional API
  useEffect(() => {
    if (!mapRef.current || mapInstance) return;

    const initMap = async () => {
      try {
        setOptions({
          apiKey: GOOGLE_MAPS_API_KEY,
          version: 'weekly',
        });

        const { Map } = await importLibrary('maps');
        
        const newMap = new Map(mapRef.current, {
          center: BHUBANESWAR_CENTER,
          zoom: DEFAULT_ZOOM,
          mapId: 'DEMO_MAP_ID',
          disableDefaultUI: false,
          zoomControl: true,
          streetViewControl: false,
          fullscreenControl: false,
          mapTypeControl: false,
        });

        // Add map click listener
        newMap.addListener('click', (e) => {
          const { onMapClick, selectingMode } = clickHandlersRef.current;
          if (selectingMode && onMapClick) {
            onMapClick(e.latLng.lat(), e.latLng.lng());
          }
        });

        setMapInstance(newMap);
      } catch (err) {
        console.error('Error initializing map:', err);
      }
    };

    initMap();
  }, [mapInstance]);

  // Update Center & Zoom dynamically (explicit mapCenter prop)
  useEffect(() => {
    if (!mapInstance || !mapCenter || !mapCenter.lat || !mapCenter.lng) return;
    mapInstance.panTo({ lat: mapCenter.lat, lng: mapCenter.lng });
    if (mapCenter.zoom) {
      mapInstance.setZoom(mapCenter.zoom);
    }
  }, [mapInstance, mapCenter]);

  // Auto-follow a streaming location (driver GPS or active driver for customer)
  useEffect(() => {
    if (!mapInstance || !followLatLng || !followLatLng.lat || !followLatLng.lng) return;
    const prev = lastFollowPosRef.current;
    // Only pan if position changed by >~5 metres (avoids jitter on tiny GPS drift)
    const THRESHOLD = 0.00005;
    if (
      prev &&
      Math.abs(followLatLng.lat - prev.lat) < THRESHOLD &&
      Math.abs(followLatLng.lng - prev.lng) < THRESHOLD
    ) return;
    lastFollowPosRef.current = { lat: followLatLng.lat, lng: followLatLng.lng };
    mapInstance.panTo({ lat: followLatLng.lat, lng: followLatLng.lng });
  }, [mapInstance, followLatLng]);

  // Render Markers and Polylines
  useEffect(() => {
    if (!mapInstance) return;

    const updateMapOverlays = async () => {
      try {
        const { AdvancedMarkerElement, PinElement } = await importLibrary('marker');
        const mapsLib = await importLibrary('maps');
        const overlays = mapOverlayRef.current;

        // 1. Pickup Marker
        if (overlays.pickupMarker) overlays.pickupMarker.map = null;
        if (pickupLatLng && pickupLatLng.lat && pickupLatLng.lng) {
          const pin = new PinElement({
            background: '#2e7d32',
            borderColor: '#1b5e20',
            glyphColor: '#ffffff',
          });
          overlays.pickupMarker = new AdvancedMarkerElement({
            map: mapInstance,
            position: { lat: pickupLatLng.lat, lng: pickupLatLng.lng },
            content: pin.element,
            title: 'Pickup Location',
          });
        }

        // 2. Dropoff Marker
        if (overlays.dropoffMarker) overlays.dropoffMarker.map = null;
        if (dropoffLatLng && dropoffLatLng.lat && dropoffLatLng.lng) {
          const pin = new PinElement({
            background: '#c62828',
            borderColor: '#b71c1c',
            glyphColor: '#ffffff',
          });
          overlays.dropoffMarker = new AdvancedMarkerElement({
            map: mapInstance,
            position: { lat: dropoffLatLng.lat, lng: dropoffLatLng.lng },
            content: pin.element,
            title: 'Drop-off Location',
          });
        }

        // 3. User Live Location Dot
        if (overlays.userMarker) overlays.userMarker.map = null;
        if (userLatLng && userLatLng.lat && userLatLng.lng) {
          const userDot = document.createElement('div');
          userDot.innerHTML = `
            <div style="
              width: 16px;
              height: 16px;
              border-radius: 50%;
              background: #1a73e8;
              border: 2.5px solid #fff;
              box-shadow: 0 0 8px rgba(26,115,232,0.6);
              position: relative;
              display: flex;
              align-items: center;
              justify-content: center;
            ">
              <div style="
                position: absolute;
                width: 24px;
                height: 24px;
                border-radius: 50%;
                border: 1.5px solid rgba(26,115,232,0.7);
                animation: pulse-ring 1.8s infinite ease-out;
                pointer-events: none;
              "></div>
            </div>
          `;
          overlays.userMarker = new AdvancedMarkerElement({
            map: mapInstance,
            position: { lat: userLatLng.lat, lng: userLatLng.lng },
            content: userDot,
            title: 'Your Live Location',
          });
        }

        // 4. Customer Live Location viewed by driver
        if (overlays.customerLiveMarker) overlays.customerLiveMarker.map = null;
        if (customerLiveLatLng && customerLiveLatLng.lat && customerLiveLatLng.lng) {
          const userDot = document.createElement('div');
          userDot.innerHTML = `
            <div style="
              width: 16px;
              height: 16px;
              border-radius: 50%;
              background: #1a73e8;
              border: 2.5px solid #fff;
              box-shadow: 0 0 8px rgba(26,115,232,0.6);
              position: relative;
              display: flex;
              align-items: center;
              justify-content: center;
            ">
              <div style="
                position: absolute;
                width: 24px;
                height: 24px;
                border-radius: 50%;
                border: 1.5px solid rgba(26,115,232,0.7);
                animation: pulse-ring 1.8s infinite ease-out;
                pointer-events: none;
              "></div>
            </div>
          `;
          overlays.customerLiveMarker = new AdvancedMarkerElement({
            map: mapInstance,
            position: { lat: customerLiveLatLng.lat, lng: customerLiveLatLng.lng },
            content: userDot,
            title: 'Customer Live Location',
          });
        }

        // 5. Driver Markers
        const newDriverIds = new Set(drivers.map(d => d.id));
        
        // Remove drivers that are no longer active/present
        Object.keys(overlays.driverMarkers).forEach((id) => {
          if (!newDriverIds.has(id)) {
            overlays.driverMarkers[id].map = null;
            delete overlays.driverMarkers[id];
          }
        });

        // Add or update active driver markers
        drivers.forEach((driver) => {
          if (!driver.lat || !driver.lng || driver.status === 'offline') {
            if (overlays.driverMarkers[driver.id]) {
              overlays.driverMarkers[driver.id].map = null;
              delete overlays.driverMarkers[driver.id];
            }
            return;
          }

          const position = { lat: driver.lat, lng: driver.lng };
          const name = driver.name ? driver.name.split(' ')[0] : 'Driver';
          const emoji = driver.vehicleType === 'bike' ? '🏍️' : '🚚';
          const statusClass = driver.status === 'online' ? 'online' : 'busy';

          // Check if marker already exists, if so pan/move position
          if (overlays.driverMarkers[driver.id]) {
            overlays.driverMarkers[driver.id].position = position;
            
            // Re-render HTML content in case name or status changed
            const content = overlays.driverMarkers[driver.id].content;
            if (content) {
              content.className = `driver-marker-dot ${statusClass}`;
              const labelEl = content.querySelector('.driver-marker-label');
              if (labelEl) labelEl.textContent = name;
            }
          } else {
            // Create custom marker DOM element
            const markerDiv = document.createElement('div');
            markerDiv.className = `driver-marker-dot ${statusClass}`;
            
            // Add wrapper styles for mapping to existing CSS
            const outerDiv = document.createElement('div');
            outerDiv.className = 'driver-marker-icon';
            
            markerDiv.innerHTML = `
              <span class="driver-marker-label">${name}</span>
              <span style="font-size: 24px; display: flex; align-items: center; justify-content: center;">${emoji}</span>
            `;
            outerDiv.appendChild(markerDiv);

            overlays.driverMarkers[driver.id] = new AdvancedMarkerElement({
              map: mapInstance,
              position,
              content: outerDiv,
              title: `${driver.name} (${driver.vehicleReg || 'No Reg'})`,
            });
          }
        });

        // 6. Route Polyline
        if (overlays.polyline) overlays.polyline.setMap(null);
        if (routeCoords && routeCoords.length > 1) {
          const path = routeCoords.map((coord) => ({ lat: coord[0], lng: coord[1] }));
          
          overlays.polyline = new mapsLib.Polyline({
            path,
            geodesic: true,
            strokeColor: '#0ea5e9',
            strokeOpacity: 0.8,
            strokeWeight: 4,
            map: mapInstance,
          });
        }
      } catch (err) {
        console.error('Error updating map overlays:', err);
      }
    };

    updateMapOverlays();
  }, [mapInstance, pickupLatLng, dropoffLatLng, drivers, userLatLng, customerLiveLatLng, routeCoords]);

  // Clean up all overlays on unmount
  useEffect(() => {
    return () => {
      const overlays = mapOverlayRef.current;
      if (overlays.pickupMarker) overlays.pickupMarker.map = null;
      if (overlays.dropoffMarker) overlays.dropoffMarker.map = null;
      if (overlays.userMarker) overlays.userMarker.map = null;
      if (overlays.customerLiveMarker) overlays.customerLiveMarker.map = null;
      Object.keys(overlays.driverMarkers).forEach((id) => {
        overlays.driverMarkers[id].map = null;
      });
      if (overlays.polyline) overlays.polyline.setMap(null);
    };
  }, []);

  const cursorStyle = selectingMode ? { cursor: 'crosshair' } : {};

  return (
    <div
      className="map-container"
      style={{ height, width: '100%', position: 'relative', ...cursorStyle }}
    >
      <div ref={mapRef} style={{ width: '100%', height: '100%' }} />
      {selectingMode && (
        <div style={{
          position: 'absolute', bottom: '12px', left: '50%', transform: 'translateX(-50%)',
          background: selectingMode === 'pickup' ? '#2e7d32' : '#c62828',
          color: '#fff', padding: '6px 14px', borderRadius: '20px', fontSize: '12px',
          fontWeight: 'bold', zIndex: 10, pointerEvents: 'none',
          boxShadow: '0 2px 8px rgba(0,0,0,0.2)',
          whiteSpace: 'nowrap',
        }}>
          {selectingMode === 'pickup' ? '📍 Tap to set Pickup' : '📍 Tap to set Dropoff'}
        </div>
      )}
    </div>
  );
}
// Source: Google Maps Platform Code Assist
