# AllTracks - Hiking Trail Management System

A decentralized application built on the Internet Computer for managing hiking trails, tracks, and group activities.

## Features

- Trail Management
  - Create and search trails
  - Track difficulty levels and trail types
  - Add photos and checkpoints
  - Rate and tag trails

- Track Recording
  - Record hiking tracks with GPS data
  - Track distance, elevation, and duration
  - Share tracks with groups
  - Mark incidents and checkpoints

- Group Features
  - Create hiking groups
  - Manage group membership
  - Share photos and tracks
  - Group activity tracking

- User Statistics
  - Track total distance hiked
  - Monitor elevation gained
  - Record completed trails
  - Calculate hiking hours

## Technology Stack

- Backend: Motoko on Internet Computer
- Frontend: React + Vite
- Styling: Sass
- Type Safety: TypeScript

## Getting Started

1. Install dependencies:
```bash
npm install


export DFX_WARNING=-mainnet_plaintext_identity
dfx canister --ic install backend --mode upgrade --wasm-memory-persistence keep