import { useEffect, useRef } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';

const BHUBANESWAR_CENTER = [20.2961, 85.8245];
const DEFAULT_ZOOM = 13;

delete L.Icon.Default.prototype._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-icon-2x.png',
  iconUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-icon.png',
  shadowUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-shadow.png',
});

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
  const mapContainerRef = useRef(null);
  const mapInstanceRef = useRef(null);
  const layerGroupRef = useRef(null);

  useEffect(() => {
    if (!mapContainerRef.current || mapInstanceRef.current) return;

    const map = L.map(mapContainerRef.current, {
      center: BHUBANESWAR_CENTER,
      zoom: DEFAULT_ZOOM,
      zoomControl: true,
    });

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors',
      maxZoom: 19,
    }).addTo(map);

    const layerGroup = L.layerGroup().addTo(map);
    layerGroupRef.current = layerGroup;
    mapInstanceRef.current = map;

    map.on('click', (e) => {
      if (onMapClick) {
        onMapClick(e.latlng.lat, e.latlng.lng);
      }
    });

    return () => {
      map.remove();
      mapInstanceRef.current = null;
    };
  }, []);

  useEffect(() => {
    if (!mapInstanceRef.current || !mapCenter || !mapCenter.lat || !mapCenter.lng) return;
    mapInstanceRef.current.panTo([mapCenter.lat, mapCenter.lng]);
    if (mapCenter.zoom) {
      mapInstanceRef.current.setZoom(mapCenter.zoom);
    }
  }, [mapCenter]);

  useEffect(() => {
    if (!mapInstanceRef.current || !followLatLng || !followLatLng.lat || !followLatLng.lng) return;
    mapInstanceRef.current.panTo([followLatLng.lat, followLatLng.lng]);
  }, [followLatLng]);

  useEffect(() => {
    if (!mapInstanceRef.current || !layerGroupRef.current) return;
    const group = layerGroupRef.current;
    group.clearLayers();

    if (pickupLatLng && pickupLatLng.lat && pickupLatLng.lng) {
      const pickupIcon = L.divIcon({
        className: 'custom-leaflet-marker',
        html: `<div style="background-color:#116E45;color:white;padding:6px 10px;border-radius:20px;font-weight:bold;font-size:11px;border:2px solid white;box-shadow:0 2px 6px rgba(0,0,0,0.3);white-space:nowrap;">📍 Pickup</div>`,
        iconAnchor: [30, 15],
      });
      L.marker([pickupLatLng.lat, pickupLatLng.lng], { icon: pickupIcon }).addTo(group);
    }

    if (dropoffLatLng && dropoffLatLng.lat && dropoffLatLng.lng) {
      const dropoffIcon = L.divIcon({
        className: 'custom-leaflet-marker',
        html: `<div style="background-color:#F26430;color:white;padding:6px 10px;border-radius:20px;font-weight:bold;font-size:11px;border:2px solid white;box-shadow:0 2px 6px rgba(0,0,0,0.3);white-space:nowrap;">🎯 Dropoff</div>`,
        iconAnchor: [30, 15],
      });
      L.marker([dropoffLatLng.lat, dropoffLatLng.lng], { icon: dropoffIcon }).addTo(group);
    }

    drivers.forEach((driver) => {
      if (!driver.lat || !driver.lng || driver.status === 'offline') return;

      const emoji = driver.vehicle_type === 'bike' ? '🏍️' : '🚚';
      const name = driver.name ? driver.name.split(' ')[0] : 'Driver';
      const isOnline = driver.status === 'online';

      const driverIcon = L.divIcon({
        className: 'custom-leaflet-driver-marker',
        html: `<div style="background:${isOnline ? '#116E45' : '#2E63E8'};color:white;padding:4px 8px;border-radius:16px;font-weight:bold;font-size:11px;border:2px solid white;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;gap:4px;white-space:nowrap;">
                 <span>${emoji}</span><span>${name}</span>
               </div>`,
        iconAnchor: [30, 15],
      });

      L.marker([driver.lat, driver.lng], { icon: driverIcon })
        .bindPopup(`<b>${driver.name}</b><br/>Plate: ${driver.vehicle_reg || 'N/A'}<br/>Status: ${driver.status.toUpperCase()}`)
        .addTo(group);
    });

    if (routeCoords && routeCoords.length > 1) {
      const latLngs = routeCoords.map((c) => [c[0], c[1]]);
      L.polyline(latLngs, { color: '#F26430', weight: 4, opacity: 0.8 }).addTo(group);
    }
  }, [pickupLatLng, dropoffLatLng, drivers, routeCoords]);

  return (
    <div style={{ height, width: '100%', position: 'relative' }}>
      <div ref={mapContainerRef} style={{ height: '100%', width: '100%' }} />
      {selectingMode && (
        <div style={{
          position: 'absolute', bottom: '16px', left: '50%', transform: 'translateX(-50%)',
          background: selectingMode === 'pickup' ? '#116E45' : '#F26430',
          color: '#fff', padding: '6px 14px', borderRadius: '20px', fontSize: '12px',
          fontWeight: 'bold', zIndex: 1000, pointerEvents: 'none',
          boxShadow: '0 2px 8px rgba(0,0,0,0.3)',
        }}>
          {selectingMode === 'pickup' ? '📍 Click map to set Pickup' : '🎯 Click map to set Dropoff'}
        </div>
      )}
    </div>
  );
}
