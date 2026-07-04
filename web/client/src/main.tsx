import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles/app.css";

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("missing #root element");

// No StrictMode: it double-invokes effects in dev, which would dispose and never re-acquire the
// live mic stream/AudioContext — disruptive for an app whose core state is a hardware side effect,
// not helpful the way it is for pure render logic.
createRoot(rootElement).render(<App />);
