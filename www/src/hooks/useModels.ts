import * as React from "react";
import { dispatch } from "@/state/store";
import type { Model } from "@/domain/models";

/** Loads the available models from the backend (model/list) once on mount.
 *  Returns [] until loaded; callers fall back to a static list when empty. */
export function useModels(): Model[] {
  const [models, setModels] = React.useState<Model[]>([]);
  React.useEffect(() => {
    let alive = true;
    dispatch
      .listModels()
      .then((m) => { if (alive && m.length) setModels(m); })
      .catch(() => {});
    return () => { alive = false; };
  }, []);
  return models;
}
