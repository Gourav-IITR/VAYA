import { useState, useEffect, useRef, useCallback } from 'react';
import { setOptions, importLibrary } from '@googlemaps/js-api-loader';

const NOMINATIM_BASE = 'https://nominatim.openstreetmap.org/search';
const VIEWBOX = '85.70,20.40,85.95,20.20';

const GOOGLE_MAPS_API_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY || '';

export default function LocationSearch({
  label = 'Location',
  value = '',
  onSelect = null,
  placeholder = 'Search for a location...',
  accentColor = 'var(--primary)',
}) {
  const [query, setQuery] = useState(value);
  const [suggestions, setSuggestions] = useState([]);
  const [isOpen, setIsOpen] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const wrapperRef = useRef(null);
  const debounceRef = useRef(null);

  // Google Maps SDK references
  const [googleMapsLoaded, setGoogleMapsLoaded] = useState(false);
  const placesLibraryRef = useRef(null);
  const sessionTokenRef = useRef(null);

  // Sync external value changes
  useEffect(() => {
    setQuery(value);
  }, [value]);

  // Close dropdown when clicking outside
  useEffect(() => {
    function handleClickOutside(e) {
      if (wrapperRef.current && !wrapperRef.current.contains(e.target)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Initialize Google Maps loader using the functional API
  useEffect(() => {
    if (!GOOGLE_MAPS_API_KEY) {
      console.warn('VITE_GOOGLE_MAPS_API_KEY is not defined. Falling back to Nominatim.');
      return;
    }

    try {
      setOptions({
        apiKey: GOOGLE_MAPS_API_KEY,
        version: 'weekly',
      });

      importLibrary('places')
        .then((library) => {
          placesLibraryRef.current = library;
          sessionTokenRef.current = new library.AutocompleteSessionToken();
          setGoogleMapsLoaded(true);
          console.log('✅ Google Places API (New) loaded successfully.');
        })
        .catch((err) => {
          console.error('Failed to import places library:', err);
        });
    } catch (err) {
      console.error('Google Maps Loader error:', err);
    }
  }, []);

  // Autocomplete search (Google Places or Nominatim fallback)
  const searchLocations = useCallback(async (searchQuery) => {
    if (!searchQuery || searchQuery.trim().length < 2) {
      setSuggestions([]);
      setIsOpen(false);
      return;
    }

    setIsLoading(true);
    
    // Try Google Places Autocomplete first
    if (googleMapsLoaded && placesLibraryRef.current) {
      try {
        const { AutocompleteSuggestion } = placesLibraryRef.current;
        
        // Bhubaneswar bounding box biasing
        const bounds = {
          north: 20.40,
          south: 20.20,
          east: 85.95,
          west: 85.70,
        };

        const request = {
          input: searchQuery,
          sessionToken: sessionTokenRef.current,
          locationRestriction: bounds,
        };

        const { suggestions: placeSuggestions } = await AutocompleteSuggestion.fetchAutocompleteSuggestions(request);
        
        // Map predictions to standard internal format
        const formatted = placeSuggestions.map((s) => ({
          place_id: s.placePrediction.placeId,
          display_name: s.placePrediction.text.text,
          source: 'google',
          description: s.placePrediction.structuredFormat?.secondaryText?.text || 'Location',
        }));

        setSuggestions(formatted);
        setIsOpen(formatted.length > 0);
        setIsLoading(false);
        return;
      } catch (err) {
        console.warn('Google Places autocomplete failed, falling back to Nominatim:', err);
      }
    }

    // Fallback: Nominatim OpenStreetMap Search
    try {
      const url = `${NOMINATIM_BASE}?format=json&q=${encodeURIComponent(searchQuery)}&viewbox=${VIEWBOX}&bounded=1&limit=6`;
      const response = await fetch(url, {
        headers: { 'Accept-Language': 'en' },
      });
      const data = await response.json();
      
      const formatted = data.map((d) => ({
        place_id: d.place_id,
        display_name: d.display_name,
        source: 'nominatim',
        lat: d.lat,
        lon: d.lon,
        description: d.type ? d.type.replace(/_/g, ' ') : 'location',
      }));

      setSuggestions(formatted);
      setIsOpen(formatted.length > 0);
    } catch (err) {
      console.error('Nominatim autocomplete error:', err);
      setSuggestions([]);
    } finally {
      setIsLoading(false);
    }
  }, [googleMapsLoaded]);

  const handleInputChange = (e) => {
    const val = e.target.value;
    setQuery(val);

    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      searchLocations(val);
    }, 300);
  };

  const handleSelect = async (suggestion) => {
    setIsOpen(false);
    setSuggestions([]);
    setIsLoading(true);

    const displayName = suggestion.display_name;
    const shortName = displayName.length > 60
      ? displayName.substring(0, 57) + '...'
      : displayName;

    setQuery(shortName);

    if (suggestion.source === 'google') {
      try {
        const { Place } = placesLibraryRef.current;
        const place = new Place({ id: suggestion.place_id });
        
        // Fetch location coordinates and display name
        await place.fetchFields({ fields: ['location', 'displayName'] });
        
        const lat = place.location.lat();
        const lng = place.location.lng();

        // Refresh session token for subsequent searches
        if (placesLibraryRef.current) {
          sessionTokenRef.current = new placesLibraryRef.current.AutocompleteSessionToken();
        }

        setIsLoading(false);
        if (onSelect) {
          onSelect({
            lat,
            lng,
            displayName: place.displayName || displayName,
          });
        }
        return;
      } catch (err) {
        console.error('Error fetching Google Place details:', err);
      }
    }

    // Nominatim path (direct lat/lon available)
    setIsLoading(false);
    if (onSelect) {
      onSelect({
        lat: parseFloat(suggestion.lat),
        lng: parseFloat(suggestion.lon),
        displayName: displayName,
      });
    }
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Escape') {
      setIsOpen(false);
    }
  };

  const truncateName = (name, maxLen = 80) => {
    if (!name) return '';
    return name.length > maxLen ? name.substring(0, maxLen - 3) + '...' : name;
  };

  return (
    <div className="form-group location-search-wrapper" ref={wrapperRef}>
      <label className="form-label" style={{ color: accentColor }}>
        {label}
      </label>

      <div style={{ position: 'relative' }}>
        <input
          type="text"
          className="form-input"
          value={query}
          onChange={handleInputChange}
          onKeyDown={handleKeyDown}
          onFocus={() => {
            if (suggestions.length > 0) setIsOpen(true);
          }}
          placeholder={placeholder}
          style={{
            width: '100%',
            paddingRight: isLoading ? '36px' : '14px',
          }}
        />

        {isLoading && (
          <div
            style={{
              position: 'absolute',
              right: '12px',
              top: '50%',
              transform: 'translateY(-50%)',
              width: '16px',
              height: '16px',
              border: '2px solid var(--border-color)',
              borderTopColor: accentColor,
              borderRadius: '50%',
              animation: 'location-search-spin 0.6s linear infinite',
            }}
          />
        )}
      </div>

      {isOpen && suggestions.length > 0 && (
        <div className="location-search-dropdown">
          {suggestions.map((suggestion, index) => (
            <div
              key={`${suggestion.place_id}-${index}`}
              className="location-search-item"
              onClick={() => handleSelect(suggestion)}
            >
              <div style={{ color: 'var(--text-heading)', fontWeight: 500 }}>
                {truncateName(suggestion.display_name, 55)}
              </div>
              <div style={{ color: 'var(--text-muted)', fontSize: '11px', marginTop: '2px' }}>
                {suggestion.description}
                {suggestion.lat && suggestion.lon && (
                  <>
                    {' · '}
                    {parseFloat(suggestion.lat).toFixed(4)}°N, {parseFloat(suggestion.lon).toFixed(4)}°E
                  </>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      <style>{`
        @keyframes location-search-spin {
          to { transform: translateY(-50%) rotate(360deg); }
        }
      `}</style>
    </div>
  );
}
// Source: Google Maps Platform Code Assist
