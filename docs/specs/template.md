Feature Spec Template (docs/specs/template.md)

# Feature Specification: [Feature Name]

**Status**: Draft | In Review | Approved | In Progress | Complete
**Priority**: P0 | P1 | P2
**PRD Reference**: Section [X]
**Author**: [Name]
**Last Updated**: [Date]

## Overview
[Brief description of the feature]

## User Stories
1. As a [user], I want [action] so that [benefit]
2. ...

## Acceptance Criteria
- [ ] AC1: [Specific, testable criterion]
- [ ] AC2: ...

## Technical Design

### Architecture
[How this feature fits into the overall architecture]

### Data Models
struct FeatureModel: Codable, Identifiable {
    let id: UUID
    // ...
}

## API Endpoints (if applicable)
`GET /api/v1/feature`
`POST /api/v1/feature`

## Dependencies
[ ] Core networking module
[ ] SwiftData setup

## UI/UX Design
Figma Link: [URL]
Key screens: [List]

## Edge Cases
[Edge case and how to handle]

## Testing Plan
Unit tests for ViewModel logic
UI tests for critical flows
Performance tests for data loading

## Rollout Plan
[ ] Feature flag: feature_[name]_enabled
[ ] A/B test configuration

## Open Questions
[ ] Question 1?
