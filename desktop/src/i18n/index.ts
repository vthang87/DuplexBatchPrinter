import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import en from "./en.json";
import vi from "./vi.json";

const resources = {
  en: { translation: en },
  vi: { translation: vi },
};

export function resolveLanguage(preference: string): string {
  if (preference === "en" || preference === "vi") return preference;
  const nav = navigator.language.toLowerCase();
  return nav.startsWith("vi") ? "vi" : "en";
}

void i18n.use(initReactI18next).init({
  resources,
  lng: resolveLanguage("system"),
  fallbackLng: "en",
  interpolation: { escapeValue: false },
});

export default i18n;
