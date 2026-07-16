import { setOptions, importLibrary } from '@googlemaps/js-api-loader';

const GOOGLE_MAPS_API_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY;

function haversineMeters(a, b) {
  const R = 6371000; // Earth radius in metres
  const φ1 = (a.lat * Math.PI) / 180;
  const φ2 = (b.lat * Math.PI) / 180;
  const Δφ = ((b.lat - a.lat) * Math.PI) / 180;
  const Δλ = ((b.lng - a.lng) * Math.PI) / 180;
  const x =
    Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
    Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
  // Multiply by 1.4 to approximate road distance from straight line
  return R * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x)) * 1.4;
}

/**
 * Fetch a driving route between two lat/lng points using the
 * Google Maps Directions Service.
 *
 * @param {{ lat: number, lng: number }} origin
 * @param {{ lat: number, lng: number }} destination
 * @returns {Promise<[number,number][]>} Array of [lat,lng] pairs tracing the road path
 */
export async function fetchDrivingRoute(origin, destination) {
  if (!origin || !destination) return [];

  try {
    setOptions({ apiKey: GOOGLE_MAPS_API_KEY, version: 'weekly' });

    const { DirectionsService, TravelMode } = await importLibrary('routes');

    const service = new DirectionsService();

    return new Promise((resolve) => {
      service.route(
        {
          origin: { lat: origin.lat, lng: origin.lng },
          destination: { lat: destination.lat, lng: destination.lng },
          travelMode: TravelMode.DRIVING,
        },
        (result, status) => {
          if (status === 'OK' && result?.routes?.[0]?.overview_path) {
            const path = result.routes[0].overview_path.map((pt) => [
              pt.lat(),
              pt.lng(),
            ]);
            resolve(path);
          } else {
            console.warn('Directions API returned status:', status, '— using straight line fallback');
            resolve([
              [origin.lat, origin.lng],
              [destination.lat, destination.lng],
            ]);
          }
        }
      );
    });
  } catch (err) {
    console.error('fetchDrivingRoute error:', err);
    // Graceful fallback: straight line
    return [
      [origin.lat, origin.lng],
      [destination.lat, destination.lng],
    ];
  }
}

/**
 * Fetch a driving route AND the total road distance in metres.
 *
 * Returns `{ path, distanceMeters }`.
 * - `path` is `[lat, lng][]` for drawing the polyline on the map.
 * - `distanceMeters` is the actual road distance from the Directions API,
 *   or a haversine estimate (×1.4) when the API is unavailable.
 *
 * @param {{ lat: number, lng: number }} origin
 * @param {{ lat: number, lng: number }} destination
 * @returns {Promise<{ path: [number,number][], distanceMeters: number }>}
 */
export async function fetchDrivingRouteWithDistance(origin, destination) {
  if (!origin || !destination) return { path: [], distanceMeters: 0 };

  try {
    setOptions({ apiKey: GOOGLE_MAPS_API_KEY, version: 'weekly' });

    const { DirectionsService, TravelMode } = await importLibrary('routes');
    const service = new DirectionsService();

    return new Promise((resolve) => {
      service.route(
        {
          origin: { lat: origin.lat, lng: origin.lng },
          destination: { lat: destination.lat, lng: destination.lng },
          travelMode: TravelMode.DRIVING,
        },
        (result, status) => {
          if (status === 'OK' && result?.routes?.[0]) {
            const route = result.routes[0];

            // Sum up leg distances for total road distance
            const distanceMeters = route.legs.reduce(
              (sum, leg) => sum + (leg.distance?.value ?? 0),
              0
            );

            const path = route.overview_path.map((pt) => [pt.lat(), pt.lng()]);
            resolve({ path, distanceMeters });
          } else {
            console.warn('Directions API status:', status, '— haversine fallback');
            const distanceMeters = haversineMeters(origin, destination);
            resolve({
              path: [
                [origin.lat, origin.lng],
                [destination.lat, destination.lng],
              ],
              distanceMeters,
            });
          }
        }
      );
    });
  } catch (err) {
    console.error('fetchDrivingRouteWithDistance error:', err);
    const distanceMeters = haversineMeters(origin, destination);
    return {
      path: [
        [origin.lat, origin.lng],
        [destination.lat, destination.lng],
      ],
      distanceMeters,
    };
  }
}

/**
 * Calculate the delivery price based on road distance and vehicle type.
 *
 * Bhubaneswar market rates:
 *   Bike      — ₹40 base + ₹6/km
 *   Mini-Truck — ₹180 base + ₹10/km  (+₹0.5/kg over 100 kg)
 *   Large-Truck — ₹450 base + ₹15/km (+₹0.5/kg over 100 kg)
 *
 * @param {number} distanceMeters  – road distance in metres
 * @param {'bike'|'mini_truck'|'large_truck'} vehicleType
 * @param {number} [weightKg=50]   – cargo weight
 * @returns {number} estimated price in ₹
 */
export function calculateDeliveryPrice(distanceMeters, vehicleType, weightKg = 50) {
  const km = distanceMeters / 1000;

  let base = 40;
  let perKm = 6;

  if (vehicleType === 'mini_truck') {
    base = 180;
    perKm = 10;
  } else if (vehicleType === 'large_truck') {
    base = 450;
    perKm = 15;
  }

  // Weight surcharge for trucks (₹0.5 per kg above 100 kg)
  let weightSurcharge = 0;
  if ((vehicleType === 'mini_truck' || vehicleType === 'large_truck') && weightKg > 100) {
    weightSurcharge = (weightKg - 100) * 0.5;
  }

  return Math.max(base, Math.round(base + km * perKm + weightSurcharge));
}
