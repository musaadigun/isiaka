import { Routes, Route } from 'react-router-dom'
import RootLayout from './layouts/RootLayout.jsx'
import Home from './pages/Home.jsx'
import About from './pages/About.jsx'
import NotFound from './pages/NotFound.jsx'

/**
 * Application route table.
 *
 * Routes are nested under `RootLayout`, which renders the shared chrome
 * (navbar + footer) around an `<Outlet />`. Add new pages by dropping a
 * component in `src/pages` and registering a `<Route>` here.
 */
function App() {
  return (
    <Routes>
      <Route element={<RootLayout />}>
        <Route index element={<Home />} />
        <Route path="about" element={<About />} />
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  )
}

export default App
