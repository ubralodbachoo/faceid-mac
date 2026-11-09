# ArcFace development asset notice

This local build uses InsightFace `w600k_mbf` (MobileFaceNet / ArcFace), from the official `buffalo_s` pack. The Core ML conversion is the package committed to Glance at `b97f521397ec1197ba17768ba797cae1e628848d`. Exact download URLs, sizes, hashes and the reference ONNX digest are recorded in `model-provenance.lock.json`.

**The pretrained weights are restricted to noncommercial research under InsightFace's published terms. No commercial model license has been obtained or inferred from Glance's MIT source license.** Commercial/customer distribution is not cleared. Conversion to Core ML does not remove the underlying model restrictions.

- Model terms: https://github.com/deepinsight/insightface#license
- Official weights: https://github.com/deepinsight/insightface/releases/tag/v0.7
- Glance package: https://github.com/jonnyoo/glance/tree/b97f521397ec1197ba17768ba797cae1e628848d/glance/Models/ArcFace.mlpackage
- Glance source license: adjacent `Glance-MIT-LICENSE.txt`

The `.mlpackage`, original ONNX weights and generated build/validation outputs are local ignored assets. The small synthetic reference file contains model outputs for deterministic artificial pixel patterns, not human faces or user enrollment data. Recognition code has no credential-store or keyboard-entry dependency.
