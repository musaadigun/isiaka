import { useEffect } from 'react'

const BASE_TITLE = 'Isiaka'

/**
 * Sets `document.title` while a component is mounted and restores the
 * previous title on unmount.
 *
 * @param {string} title - Page-specific title. Rendered as "<title> · Isiaka".
 */
export function useDocumentTitle(title) {
  useEffect(() => {
    const previous = document.title
    document.title = title ? `${title} · ${BASE_TITLE}` : BASE_TITLE
    return () => {
      document.title = previous
    }
  }, [title])
}
