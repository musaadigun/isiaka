import { Outlet } from 'react-router-dom'
import Navbar from '../components/Navbar.jsx'
import Footer from '../components/Footer.jsx'

/**
 * Shared app shell. Renders the navbar and footer around the active route,
 * which is injected via `<Outlet />`.
 */
function RootLayout() {
  return (
    <>
      <Navbar />
      <main className="container" style={{ flex: 1, paddingBlock: 'var(--space-5)' }}>
        <Outlet />
      </main>
      <Footer />
    </>
  )
}

export default RootLayout
