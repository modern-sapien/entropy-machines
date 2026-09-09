import type { ReactNode } from "react";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { TopNav } from "./components/TopNav";
import { ThemeProvider } from "./context/ThemeProvider";
import { DashboardPage } from "./pages/DashboardPage";
import { DocPage } from "./pages/DocPage";
import { KitchenSinkPage } from "./pages/KitchenSinkPage";
import { LandingPage } from "./pages/LandingPage";
import { SprintReportPage } from "./pages/SprintReportPage";
import { TrackerPage } from "./pages/TrackerPage";

function Layout({ children }: { children: ReactNode }) {
  return (
    <>
      <TopNav />
      <main>{children}</main>
    </>
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <BrowserRouter>
        <Routes>
          <Route
            path="/"
            element={
              <Layout>
                <DashboardPage />
              </Layout>
            }
          />
          <Route
            path="/tracker"
            element={
              <Layout>
                <TrackerPage />
              </Layout>
            }
          />
          <Route
            path="/docs/:slug"
            element={
              <Layout>
                <DocPage />
              </Layout>
            }
          />
          <Route
            path="/reports/:slug"
            element={
              <Layout>
                <SprintReportPage />
              </Layout>
            }
          />
          <Route
            path="/prds/:slug"
            element={
              <Layout>
                <DocPage />
              </Layout>
            }
          />
          <Route
            path="/prds"
            element={
              <Layout>
                <LandingPage kind="prds" />
              </Layout>
            }
          />
          <Route
            path="/docs"
            element={
              <Layout>
                <LandingPage kind="docs" />
              </Layout>
            }
          />
          <Route
            path="/reports"
            element={
              <Layout>
                <LandingPage kind="reports" />
              </Layout>
            }
          />
          <Route
            path="/kitchen-sink"
            element={
              <Layout>
                <KitchenSinkPage />
              </Layout>
            }
          />
        </Routes>
      </BrowserRouter>
    </ThemeProvider>
  );
}
