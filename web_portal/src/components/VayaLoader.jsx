import React, { useState, useEffect, useRef, useCallback } from 'react';
import './VayaLoader.css';

// Exact Route Bezier Path Data
const ROUTE_PATH_D = "M 28 148 C 60 148 76 108 100 100 C 124 92 148 60 172 60";

// Size Map (Pixels)
const SIZE_MAP = {
  sm: 48,
  md: 96,
  lg: 160,
  xl: 224,
};

// Mini-Truck Graphic (Tata Ace / VAYA Truck)
function VehicleMiniTruck({ scale = 1.8 }) {
  return (
    <g transform={`scale(${scale})`}>
      <rect x="-14" y="-11" width="16" height="9" rx="1.2" fill="var(--vaya-ink, #0E0E0C)" />
      <path d="M 2 -8 L 8 -8 L 11 -3 L 11 -2 L 2 -2 Z" fill="var(--vaya-saffron, #F26430)" />
      <path d="M 3.5 -6.8 L 7.5 -6.8 L 9.6 -3.8 L 3.5 -3.8 Z" fill="var(--vaya-cream, #F4EFE6)" />
      <rect x="-14" y="-2" width="25" height="1.6" fill="var(--vaya-ink, #0E0E0C)" />
      <g className="vaya-wheels" style={{ transformOrigin: '-9px 1px' }}>
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center' }}>
          <circle cx="-9" cy="1" r="2.6" fill="var(--vaya-ink, #0E0E0C)" />
          <circle cx="-9" cy="1" r="0.9" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="-9" y1="-1.2" x2="-9" y2="3.2" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.4" />
        </g>
      </g>
      <g className="vaya-wheels" style={{ transformOrigin: '7px 1px' }}>
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center' }}>
          <circle cx="7" cy="1" r="2.6" fill="var(--vaya-ink, #0E0E0C)" />
          <circle cx="7" cy="1" r="0.9" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="7" y1="-1.2" x2="7" y2="3.2" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.4" />
        </g>
      </g>
    </g>
  );
}

// Three-Wheeler Auto/Cargo Graphic
function VehicleThreeWheeler({ scale = 1.8 }) {
  return (
    <g transform={`scale(${scale})`}>
      <path d="M -10 -8 Q -10 -11 -7 -11 L 3 -11 Q 6 -11 6 -8 L 6 -2 L -10 -2 Z" fill="var(--vaya-saffron, #F26430)" />
      <rect x="-7" y="-9" width="10" height="3" rx="0.5" fill="var(--vaya-cream, #F4EFE6)" />
      <rect x="-11" y="-2" width="19" height="1.4" fill="var(--vaya-ink, #0E0E0C)" />
      <g className="vaya-wheels" style={{ transformOrigin: '-7px 1px' }}>
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center' }}>
          <circle cx="-7" cy="1" r="2.4" fill="var(--vaya-ink, #0E0E0C)" />
          <circle cx="-7" cy="1" r="0.8" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="-7" y1="-1" x2="-7" y2="3" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.4" />
        </g>
      </g>
      <g className="vaya-wheels" style={{ transformOrigin: '5px 1px' }}>
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center' }}>
          <circle cx="5" cy="1" r="2.4" fill="var(--vaya-ink, #0E0E0C)" />
          <circle cx="5" cy="1" r="0.8" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="5" y1="-1" x2="5" y2="3" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.4" />
        </g>
      </g>
    </g>
  );
}

// Two-Wheeler Scooter / Bike Graphic
function VehicleTwoWheeler({ scale = 1.8 }) {
  return (
    <g transform={`scale(${scale})`}>
      <circle cx="0" cy="-10" r="1.8" fill="var(--vaya-ink, #0E0E0C)" />
      <path d="M -1.5 -8.5 L -0.5 -3.5 L 1.5 -3.5 L 2.5 -8.5 Z" fill="var(--vaya-ink, #0E0E0C)" />
      <rect x="-6" y="-6" width="4.5" height="4" rx="0.6" fill="var(--vaya-saffron, #F26430)" />
      <path d="M -5 1 L -1 -3 L 3 -3 L 6 1" stroke="var(--vaya-ink, #0E0E0C)" strokeWidth="1.2" fill="none" strokeLinecap="round" />
      <g className="vaya-wheels" style={{ transformOrigin: '-5px 1px' }}>
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center' }}>
          <circle cx="-5" cy="1" r="2.4" fill="var(--vaya-ink, #0E0E0C)" />
          <circle cx="-5" cy="1" r="0.8" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="-5" y1="-1" x2="-5" y2="3" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.4" />
        </g>
      </g>
      <g className="vaya-wheels" style={{ transformOrigin: '6px 1px' }}>
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center' }}>
          <circle cx="6" cy="1" r="2.4" fill="var(--vaya-ink, #0E0E0C)" />
          <circle cx="6" cy="1" r="0.8" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="6" y1="-1" x2="6" y2="3" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.4" />
        </g>
      </g>
    </g>
  );
}

// Select Vehicle Component based on type
function VehicleGraphic({ type }) {
  if (type === 'three-wheeler') return <VehicleThreeWheeler scale={1.8} />;
  if (type === 'two-wheeler') return <VehicleTwoWheeler scale={1.8} />;
  return <VehicleMiniTruck scale={1.8} />;
}

// Vehicle Motion Tracker along Bezier Route Curve
function VehicleRouteRunner({ routeD, routeLen, vehicleType, determinate, progress }) {
  const pathRef = useRef(null);
  const vehicleGroupRef = useRef(null);

  const updatePosition = useCallback((pct) => {
    const pathEl = pathRef.current;
    const groupEl = vehicleGroupRef.current;
    if (!pathEl || !groupEl || !routeLen) return;

    const currentLen = Math.max(0, Math.min(1, pct)) * routeLen;
    const point = pathEl.getPointAtLength(currentLen);
    const nextPoint = pathEl.getPointAtLength(Math.min(routeLen, currentLen + 0.5));
    const angle = (Math.atan2(nextPoint.y - point.y, nextPoint.x - point.x) * 180) / Math.PI;

    groupEl.setAttribute('transform', `translate(${point.x} ${point.y}) rotate(${angle})`);
  }, [routeLen]);

  const easeProgress = (t) => {
    if (t < 0.7) {
      const norm = t / 0.7;
      return norm * norm * (3 - 2 * norm);
    }
    return 1;
  };

  // Determinate mode animation
  useEffect(() => {
    if (!determinate) return;
    let animId = 0;
    let startTime = null;
    const groupEl = vehicleGroupRef.current;
    const pathEl = pathRef.current;
    if (!groupEl || !pathEl || !routeLen) return;

    const match = (groupEl.getAttribute('transform') || '').match(/translate\(([-\d.]+)\s+([-\d.]+)\)/);
    let startRatio = 0;
    if (match) {
      const curX = parseFloat(match[1]);
      const curY = parseFloat(match[2]);
      let minDist = Infinity;
      let closestRatio = 0;

      for (let i = 0; i <= 24; i++) {
        const r = i / 24;
        const pt = pathEl.getPointAtLength(r * routeLen);
        const dist = (pt.x - curX) ** 2 + (pt.y - curY) ** 2;
        if (dist < minDist) {
          minDist = dist;
          closestRatio = r;
        }
      }
      startRatio = closestRatio;
    }

    const targetRatio = progress / 100;
    const duration = 320;

    const step = (timestamp) => {
      if (startTime === null) startTime = timestamp;
      const elapsed = Math.min(1, (timestamp - startTime) / duration);
      const eased = elapsed * elapsed * (3 - 2 * elapsed);
      const curRatio = startRatio + (targetRatio - startRatio) * eased;
      updatePosition(curRatio);
      if (elapsed < 1) {
        animId = requestAnimationFrame(step);
      }
    };

    animId = requestAnimationFrame(step);
    return () => cancelAnimationFrame(animId);
  }, [determinate, progress, routeLen, updatePosition]);

  // Indeterminate master loop animation (2.0s)
  useEffect(() => {
    if (determinate || !routeLen) return;
    let animId = 0;
    const loopDuration = 2000;
    let startTime = 0;

    const loopStep = (timestamp) => {
      if (!startTime) startTime = timestamp;
      const loopTime = ((timestamp - startTime) % loopDuration) / loopDuration;
      const easedPos = easeProgress(loopTime);
      updatePosition(easedPos);

      const groupEl = vehicleGroupRef.current;
      if (groupEl) {
        let alpha = 1;
        if (loopTime < 0.06) {
          alpha = loopTime / 0.06;
        } else if (loopTime > 0.82 && loopTime < 0.92) {
          alpha = 1 - (loopTime - 0.82) / 0.1;
        } else if (loopTime >= 0.92) {
          alpha = 0;
        }
        groupEl.style.opacity = String(alpha);
      }
      animId = requestAnimationFrame(loopStep);
    };

    animId = requestAnimationFrame(loopStep);
    return () => cancelAnimationFrame(animId);
  }, [determinate, routeLen, updatePosition]);

  return (
    <>
      <path ref={pathRef} d={routeD} fill="none" stroke="none" />
      <g ref={vehicleGroupRef} data-testid="g-vaya-vehicle">
        <VehicleGraphic type={vehicleType} />
      </g>
    </>
  );
}

// Full Loader Scene SVG Renderer
function LoaderScene({ pixelSize, mode, progress, vehicleType, reduced }) {
  const isDeterminate = mode === 'determinate';
  const clampedProgress = Math.max(0, Math.min(100, progress));
  const activeRouteRef = useRef(null);
  const [totalPathLength, setTotalPathLength] = useState(180);

  useEffect(() => {
    if (activeRouteRef.current) {
      try {
        setTotalPathLength(activeRouteRef.current.getTotalLength());
      } catch (e) {}
    }
  }, []);

  const dashOffset = totalPathLength * (1 - clampedProgress / 100);
  const isComplete = isDeterminate && clampedProgress >= 100;

  return (
    <svg
      width={pixelSize}
      height={pixelSize}
      viewBox="0 0 200 200"
      fill="none"
      aria-hidden="true"
      focusable="false"
      data-testid="svg-vaya-scene"
      style={{ overflow: 'visible' }}
    >
      {/* Background Track Path */}
      <path
        d={ROUTE_PATH_D}
        stroke="var(--vaya-slate, #3C3A34)"
        strokeOpacity="0.22"
        strokeWidth="2.4"
        strokeLinecap="round"
        fill="none"
      />

      {/* Animated Saffron Revealing Route Path */}
      <path
        ref={activeRouteRef}
        d={ROUTE_PATH_D}
        stroke="var(--vaya-saffron, #F26430)"
        strokeWidth="2.8"
        strokeLinecap="round"
        fill="none"
        strokeDasharray={totalPathLength}
        style={
          isDeterminate
            ? { strokeDashoffset: dashOffset, transition: 'stroke-dashoffset 300ms ease-out' }
            : reduced
            ? { strokeDashoffset: 0, opacity: 0.85 }
            : {
                strokeDashoffset: totalPathLength,
                animation: 'vaya-route-reveal 2s cubic-bezier(0.65, 0, 0.35, 1) infinite',
                '--vaya-route-len': totalPathLength,
              }
        }
      />

      {/* Intermediate System Nodes */}
      {[
        { cx: 62, cy: 140, delay: '0.15s' },
        { cx: 100, cy: 100, delay: '0.55s' },
        { cx: 138, cy: 74, delay: '0.95s' },
      ].map((node, i) => (
        <circle
          key={i}
          cx={node.cx}
          cy={node.cy}
          r="2.2"
          fill="var(--vaya-saffron, #F26430)"
          style={
            reduced
              ? { opacity: isDeterminate ? 1 : 0.7 }
              : {
                  transformBox: 'fill-box',
                  transformOrigin: 'center',
                  animation: 'vaya-node-pulse 2s ease-in-out infinite',
                  animationDelay: node.delay,
                  opacity: isDeterminate ? 1 : undefined,
                }
          }
        />
      ))}

      {/* Pickup Marker (Saffron Filled + Pulse Ring) */}
      <g style={{ transform: 'translate(28px, 148px)' }}>
        <rect
          x="-4"
          y="-4"
          width="8"
          height="8"
          rx="1"
          fill="var(--vaya-saffron, #F26430)"
          style={
            reduced
              ? undefined
              : {
                  transformBox: 'fill-box',
                  transformOrigin: 'center',
                  animation: 'vaya-pickup-pulse 2s ease-in-out infinite',
                }
          }
        />
      </g>

      {/* Drop Marker (Open Stroke Ring) */}
      <g style={{ transform: 'translate(172px, 60px)' }}>
        <circle
          cx="0"
          cy="0"
          r="5"
          fill="var(--vaya-cream, #F4EFE6)"
          stroke="var(--vaya-saffron, #F26430)"
          strokeWidth="2.2"
          style={
            reduced
              ? undefined
              : {
                  transformBox: 'fill-box',
                  transformOrigin: 'center',
                  animation: 'vaya-drop-pulse 2s ease-in-out infinite',
                }
          }
        />
      </g>

      {/* Moving Vehicle */}
      {!reduced && !isComplete && (
        <VehicleRouteRunner
          routeD={ROUTE_PATH_D}
          routeLen={totalPathLength}
          vehicleType={vehicleType}
          determinate={isDeterminate}
          progress={clampedProgress}
        />
      )}

      {/* V-Mark Logo Morph (Shown on completion or reduced motion) */}
      {(reduced || isComplete) && (
        <g
          data-testid="svg-vaya-completion"
          style={{
            animation: reduced
              ? 'vaya-reduced-crossfade 2.6s ease-in-out infinite'
              : 'vaya-vmark-in 380ms ease-out both',
            transformOrigin: 'center',
          }}
        >
          <path
            d="M 60 60 L 100 140 L 148 40 L 138 36"
            stroke="var(--vaya-ink, #0E0E0C)"
            strokeWidth="14"
            strokeLinecap="square"
            strokeLinejoin="miter"
            fill="none"
          />
        </g>
      )}
    </svg>
  );
}

// Inline Loader Component (Compact Wheel for Buttons & Form Inputs)
function InlineLoader({ label }) {
  return (
    <span
      role="status"
      aria-live="polite"
      aria-busy="true"
      aria-label={label}
      data-vaya-loader="inline"
      data-testid="loader-inline"
      className="vaya-loader vaya-loader--inline"
      style={{ display: 'inline-flex', alignItems: 'center', verticalAlign: 'middle', width: '1.15em', height: '1.15em' }}
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        aria-hidden="true"
        focusable="false"
        style={{ width: '100%', height: '100%' }}
      >
        <path
          d="M 3 18 L 10 11 L 15 15 L 21 6"
          stroke="currentColor"
          strokeWidth="2.2"
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeDasharray="30"
          style={{ animation: 'vaya-inline-chevron 1.2s cubic-bezier(0.65, 0, 0.35, 1) infinite' }}
          opacity="0.35"
        />
        <g style={{ transformBox: 'fill-box', transformOrigin: 'center', animation: 'vaya-wheel-spin 900ms linear infinite' }}>
          <circle cx="12" cy="12" r="4.2" fill="currentColor" />
          <circle cx="12" cy="12" r="1.4" fill="var(--vaya-cream, #F4EFE6)" />
          <line x1="12" y1="8" x2="12" y2="16" stroke="var(--vaya-cream, #F4EFE6)" strokeWidth="0.9" />
        </g>
      </svg>
      <span className="vaya-sr-only">{label}</span>
    </span>
  );
}

/**
 * Main VayaLoader Component
 */
export default function VayaLoader({
  variant = 'section',
  size = 'md',
  theme = 'system',
  message,
  showMessage,
  progress,
  mode,
  vehicleType = 'mini-truck',
  reducedMotion = false,
  accessibleLabel,
  showDelayMs = 120,
  minimumDisplayDuration = 400,
  active = true,
  blur = true,
  className = '',
  style = {},
}) {
  const [shouldRender, setShouldRender] = useState(active && showDelayMs === 0);
  const mountTimeRef = useRef(null);
  const delayTimerRef = useRef(null);
  const hideTimerRef = useRef(null);

  // Debounce & minimum duration handling
  useEffect(() => {
    if (active) {
      if (delayTimerRef.current) clearTimeout(delayTimerRef.current);
      if (hideTimerRef.current) clearTimeout(hideTimerRef.current);

      if (showDelayMs > 0) {
        delayTimerRef.current = setTimeout(() => {
          setShouldRender(true);
          mountTimeRef.current = Date.now();
        }, showDelayMs);
      } else {
        setShouldRender(true);
        mountTimeRef.current = Date.now();
      }
    } else {
      if (delayTimerRef.current) clearTimeout(delayTimerRef.current);

      const elapsed = mountTimeRef.current ? Date.now() - mountTimeRef.current : minimumDisplayDuration;
      const remainingTime = Math.max(0, minimumDisplayDuration - elapsed);

      hideTimerRef.current = setTimeout(() => {
        setShouldRender(false);
        mountTimeRef.current = null;
      }, remainingTime);
    }

    return () => {
      if (delayTimerRef.current) clearTimeout(delayTimerRef.current);
      if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
    };
  }, [active, showDelayMs, minimumDisplayDuration]);

  // Reduced motion preference hook
  const [effectiveReduced, setEffectiveReduced] = useState(reducedMotion);
  useEffect(() => {
    if (reducedMotion) {
      setEffectiveReduced(true);
    } else {
      const match = window.matchMedia && window.matchMedia('(prefers-color-scheme: reduce)').matches;
      setEffectiveReduced(match);
    }
  }, [reducedMotion]);

  const isDeterminate = typeof progress === 'number' && Number.isFinite(progress);
  const derivedMode = mode || (isDeterminate ? 'determinate' : 'indeterminate');
  const clampedProgress = isDeterminate ? Math.max(0, Math.min(100, progress)) : 0;

  const [autoShowMsg, setAutoShowMsg] = useState(false);
  useEffect(() => {
    if (!shouldRender || !message || derivedMode === 'determinate') {
      setAutoShowMsg(false);
      return;
    }
    const timer = setTimeout(() => setAutoShowMsg(true), 2000);
    return () => clearTimeout(timer);
  }, [shouldRender, message, derivedMode]);

  const displayMessage = message && (showMessage ?? (derivedMode === 'determinate' ? true : autoShowMsg));
  const label = accessibleLabel || message || 'Loading';
  const pixelSize = SIZE_MAP[size] || SIZE_MAP.md;

  if (variant === 'inline') {
    return shouldRender ? <InlineLoader label={label} /> : null;
  }

  if (!shouldRender) return null;

  const ariaAttributes = {
    role: 'status',
    'aria-live': 'polite',
    'aria-busy': active,
    'aria-label': label,
  };

  const progressAttributes = derivedMode === 'determinate' ? {
    'aria-valuenow': Math.round(clampedProgress),
    'aria-valuemin': 0,
    'aria-valuemax': 100,
  } : {};

  const loaderBody = (
    <div className="vaya-loader__body" style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
      <LoaderScene
        pixelSize={pixelSize}
        mode={derivedMode}
        progress={clampedProgress}
        vehicleType={vehicleType}
        reduced={effectiveReduced}
      />
      {displayMessage && (
        <p
          className="vaya-loader__message"
          style={{
            marginTop: '16px',
            maxWidth: '30ch',
            textAlign: 'center',
            fontSize: '13px',
            fontWeight: 600,
            color: 'var(--vaya-slate, #3C3A34)',
            animation: derivedMode === 'determinate' || effectiveReduced ? 'none' : 'vaya-message-breath 2.4s ease-in-out infinite',
          }}
          data-testid="text-loader-message"
        >
          {message}
          {derivedMode === 'determinate' && (
            <span style={{ marginLeft: '6px', fontWeight: 700, color: 'var(--vaya-saffron, #F26430)' }}>
              {Math.round(clampedProgress)}%
            </span>
          )}
        </p>
      )}
    </div>
  );

  if (variant === 'fullscreen') {
    return (
      <div
        {...ariaAttributes}
        data-vaya-loader="fullscreen"
        data-testid="loader-fullscreen"
        className={`vaya-loader vaya-loader--fullscreen ${className}`}
        style={{
          position: 'fixed',
          inset: 0,
          zIndex: 9999,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: 'rgba(244, 239, 230, 0.88)',
          backdropFilter: blur ? 'blur(8px)' : 'none',
          WebkitBackdropFilter: blur ? 'blur(8px)' : 'none',
          animation: effectiveReduced ? undefined : 'vaya-fade-in 220ms ease-out both',
          ...style,
        }}
      >
        <div {...progressAttributes}>
          {loaderBody}
        </div>
        <span className="vaya-sr-only">{label}</span>
      </div>
    );
  }

  return (
    <div
      {...ariaAttributes}
      data-vaya-loader="section"
      data-testid="loader-section"
      className={`vaya-loader vaya-loader--section ${className}`}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: '32px 16px',
        animation: effectiveReduced ? undefined : 'vaya-fade-in 220ms ease-out both',
        ...style,
      }}
    >
      <div {...progressAttributes}>
        {loaderBody}
      </div>
      <span className="vaya-sr-only">{label}</span>
    </div>
  );
}
