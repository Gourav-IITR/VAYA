import React from 'react';

export default function VayaLogo({ variant = 'wordmark', size = 32, color = 'currentColor' }) {
  // SVG of the custom V checkmark symbol
  const renderSymbol = (customColor) => (
    <svg 
      width={size} 
      height={size} 
      viewBox="0 0 100 100" 
      fill="none" 
      xmlns="http://www.w3.org/2000/svg"
      style={{ display: 'inline-block', verticalAlign: 'middle' }}
    >
      <path 
        d="M22 46 L43 73 L49 73 L78 27 L66 27 L46 58 L32 46 Z" 
        fill={customColor || "#F26430"} 
      />
    </svg>
  );

  const renderWordmark = () => (
    <span style={{ 
      fontFamily: 'var(--font-display)', 
      fontWeight: 800, 
      fontSize: `${size * 0.75}px`,
      letterSpacing: '0.04em',
      color: color === 'currentColor' ? 'var(--ink-black)' : color,
      display: 'inline-flex',
      alignItems: 'center',
      userSelect: 'none'
    }}>
      V<span style={{ color: 'var(--primary)' }}>Λ</span>Y<span style={{ color: 'var(--primary)' }}>Λ</span>
    </span>
  );

  if (variant === 'symbol') {
    return renderSymbol(color === 'currentColor' ? 'var(--primary)' : color);
  }

  if (variant === 'stacked') {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '8px' }}>
        {renderSymbol('#F26430')}
        {renderWordmark()}
      </div>
    );
  }

  if (variant === 'icon') {
    // Saffron background with white V symbol
    return (
      <div style={{
        width: `${size}px`,
        height: `${size}px`,
        backgroundColor: '#F26430',
        borderRadius: `${size * 0.22}px`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        boxShadow: 'var(--shadow-md)'
      }}>
        {renderSymbol('#ffffff')}
      </div>
    );
  }

  // Default: wordmark with preceding symbol
  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: '10px' }}>
      {renderSymbol('#F26430')}
      {renderWordmark()}
    </div>
  );
}
