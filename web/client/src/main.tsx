import { createRoot } from "react-dom/client";
import App from "./App";
import { DeleteDataScreen } from "./screens/DeleteDataScreen";
import "./styles/app.css";

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("missing #root element");

// Routed here (not inside App) so the enrollment flow's hooks never conditionally skip — the
// pathname is fixed for the lifetime of a page load, but branching on it inside a component with
// hooks below the branch is a real Rules-of-Hooks violation regardless.
const isDeleteRoute = window.location.pathname === "/delete";

// No StrictMode: it double-invokes effects in dev, which would dispose and never re-acquire the
// live mic stream/AudioContext — disruptive for an app whose core state is a hardware side effect,
// not helpful the way it is for pure render logic.
createRoot(rootElement).render(isDeleteRoute ? <DeleteDataScreen /> : <App />);
