# Architecture (High Level)

KORE uses a closed-loop neurofeedback system designed for high-frequency sensing with low latency. This document is a placeholder for architecture details.

## Components
- Wearable EEG + tACS patch (edge sensing and stimulation)
- Mobile/desktop app (user control surface)
- AI inference services (prediction and personalization)

## Data Flow (Draft)
1. EEG sensing -> edge preprocessing
2. Edge -> app telemetry stream
3. AI inference -> Cognitive Bandwidth Meter
4. App triggers reset session -> patch stimulation

## Notes
- Latency, sampling rates, and storage constraints are TBD.
- Safety and compliance requirements will be documented here.
