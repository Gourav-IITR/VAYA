import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import React from 'react';
import VayaLoader from './VayaLoader';

describe('VayaLoader Component', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('returns nothing when active is false', () => {
    const { container } = render(<VayaLoader active={false} showDelayMs={0} />);
    expect(container.firstChild).toBeNull();
  });

  it('delayed appearance prevents flashes for fast requests', () => {
    const { container } = render(<VayaLoader active={true} showDelayMs={120} />);
    expect(container.firstChild).toBeNull();

    act(() => {
      vi.advanceTimersByTime(50);
    });
    expect(container.firstChild).toBeNull();

    act(() => {
      vi.advanceTimersByTime(100);
    });
    expect(container.firstChild).not.toBeNull();
  });

  it('minimum visible duration works', () => {
    const { rerender, container } = render(
      <VayaLoader active={true} showDelayMs={0} minimumDisplayDuration={400} />
    );

    act(() => {
      vi.advanceTimersByTime(50);
    });

    rerender(<VayaLoader active={false} showDelayMs={0} minimumDisplayDuration={400} />);
    
    expect(container.firstChild).not.toBeNull();

    act(() => {
      vi.advanceTimersByTime(600);
    });
    expect(container.firstChild).toBeNull();
  });

  it('all three variants render correctly', () => {
    const { rerender } = render(<VayaLoader variant="section" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveClass('vaya-loader--section');

    rerender(<VayaLoader variant="fullscreen" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveClass('vaya-loader--fullscreen');

    rerender(<VayaLoader variant="inline" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveClass('vaya-loader--inline');
  });

  it('all supported sizes work', () => {
    const sizes = ['sm', 'md', 'lg', 'xl'];
    sizes.forEach((size) => {
      const { container, unmount } = render(<VayaLoader size={size} showDelayMs={0} />);
      expect(container.firstChild).toHaveClass(`vaya-loader--${size}`);
      unmount();
    });
  });

  it('progress is clamped to 0–100', () => {
    const { rerender } = render(<VayaLoader progress={-20} showDelayMs={0} />);
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '0');

    rerender(<VayaLoader progress={150} showDelayMs={0} />);
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '100');
  });

  it('numeric progress automatically selects determinate mode', () => {
    render(<VayaLoader progress={45} showDelayMs={0} />);
    const loader = screen.getByRole('progressbar');
    expect(loader).toHaveClass('vaya-loader--determinate');
    expect(loader).toHaveAttribute('aria-valuenow', '45');
  });

  it('determinate ARIA attributes are correct', () => {
    render(<VayaLoader progress={60} showDelayMs={0} />);
    const progressbar = screen.getByRole('progressbar');
    expect(progressbar).toHaveAttribute('aria-valuenow', '60');
    expect(progressbar).toHaveAttribute('aria-valuemin', '0');
    expect(progressbar).toHaveAttribute('aria-valuemax', '100');
  });

  it('indeterminate status semantics are correct', () => {
    render(<VayaLoader mode="indeterminate" showDelayMs={0} />);
    const status = screen.getByRole('status');
    expect(status).toHaveAttribute('aria-live', 'polite');
    expect(status).toHaveAttribute('aria-busy', 'true');
  });

  it('accessible label falls back to message and then Loading', () => {
    const { rerender } = render(<VayaLoader showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveAttribute('aria-label', 'Loading');

    rerender(<VayaLoader message="Preparing route" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveAttribute('aria-label', 'Preparing route');

    rerender(<VayaLoader message="Preparing route" accessibleLabel="Custom accessible label" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveAttribute('aria-label', 'Custom accessible label');
  });

  it('explicit reduced-motion override is honored', () => {
    render(<VayaLoader reducedMotion={true} showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveClass('vaya-loader--reduced-motion');
  });

  it('theme classes work in light and dark modes', () => {
    const { rerender } = render(<VayaLoader theme="light" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveClass('vaya-loader--light');

    rerender(<VayaLoader theme="dark" showDelayMs={0} />);
    expect(screen.getByRole('status')).toHaveClass('vaya-loader--dark');
  });
});
