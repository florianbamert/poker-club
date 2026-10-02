// =====================================================================
// Reine Spiellogik, ohne DB- oder Netzwerk-Zugriff — darum einfach lokal
// mit Node/Deno testbar. evaluate5/evaluate7/compareHandArrays sind
// wortwörtlich aus poker-club.html übernommen (dort ab Zeile ~8158),
// damit Online-Spiel und Live-Erfassung/Replay garantiert dieselbe
// Hand-Bewertung verwenden — keine zweite, potenziell abweichende
// Implementierung (siehe "Bekannte Bugs"-Dokument: Live-vs-Replay-
// Duplikation war schon mal die Ursache echter Bugs).
//
// Karten-Format identisch zur App: Rang + Farb-Symbol, z. B. 'A♠', 'T♦'.
// =====================================================================

export const RANK_VALUES: Record<string, number> = {
  '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7, '8': 8, '9': 9,
  'T': 10, 'J': 11, 'Q': 12, 'K': 13, 'A': 14,
};

export function combinations<T>(arr: T[], k: number): T[][] {
  const result: T[][] = [];
  function helper(start: number, combo: T[]) {
    if (combo.length === k) { result.push(combo.slice()); return; }
    for (let i = start; i < arr.length; i++) { combo.push(arr[i]); helper(i + 1, combo); combo.pop(); }
  }
  helper(0, []);
  return result;
}

export function evaluate5(cards: string[]): number[] {
  const ranks = cards.map(c => RANK_VALUES[c.slice(0, -1)]).sort((a, b) => b - a);
  const suits = cards.map(c => c.slice(-1));
  const isFlush = suits.every(s => s === suits[0]);
  const uniqueRanks = [...new Set(ranks)];
  let isStraight = false, straightHigh = 0;
  if (uniqueRanks.length === 5) {
    if (uniqueRanks[0] - uniqueRanks[4] === 4) { isStraight = true; straightHigh = uniqueRanks[0]; }
    else if (uniqueRanks.join(',') === '14,5,4,3,2') { isStraight = true; straightHigh = 5; }
  }
  const countMap: Record<number, number> = {};
  ranks.forEach(r => countMap[r] = (countMap[r] || 0) + 1);
  const groups = Object.entries(countMap).map(([r, c]) => ({ rank: Number(r), count: c as number }))
    .sort((a, b) => b.count - a.count || b.rank - a.rank);
  if (isStraight && isFlush) return [8, straightHigh];
  if (groups[0].count === 4) return [7, groups[0].rank, groups[1].rank];
  if (groups[0].count === 3 && groups[1] && groups[1].count >= 2) return [6, groups[0].rank, groups[1].rank];
  if (isFlush) return [5, ...ranks];
  if (isStraight) return [4, straightHigh];
  if (groups[0].count === 3) return [3, groups[0].rank, ...groups.slice(1).map(g => g.rank)];
  if (groups[0].count === 2 && groups[1] && groups[1].count === 2) return [2, groups[0].rank, groups[1].rank, groups[2].rank];
  if (groups[0].count === 2) return [1, groups[0].rank, ...groups.slice(1).map(g => g.rank)];
  return [0, ...ranks];
}

export function evaluate7(cards: string[]): number[] {
  let best: number[] | null = null;
  combinations(cards, 5).forEach(c => {
    const val = evaluate5(c);
    if (!best || compareHandArrays(val, best) > 0) best = val;
  });
  return best as number[];
}

export function compareHandArrays(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const av = a[i] || 0, bv = b[i] || 0;
    if (av !== bv) return av - bv;
  }
  return 0;
}

// =====================================================================
// Phase-0-spezifisch: Heads-up-Betting-State-Machine (NEU, nicht aus der
// App übernommen — hier lohnt sich zusätzliche Testabdeckung, siehe
// poker.test.mjs).
// =====================================================================

export type Phase = 'waiting' | 'preflop' | 'flop' | 'turn' | 'river' | 'showdown' | 'done';

export interface HandState {
  phase: Phase;
  dealer_seat: 0 | 1;
  board: string[];
  deck: string[];
  pot: number;
  current_seat: 0 | 1;
  bets: Record<string, number>;
  acted: Record<string, number | boolean>;
  folded: Record<string, boolean>;
  last_raise_size: number;
}

export interface SeatInfo {
  seat_no: 0 | 1;
  stack: number;
}

export type ActionType = 'fold' | 'check' | 'call' | 'bet' | 'raise';

export interface ApplyActionResult {
  error?: string;
  state?: HandState;
  stacks?: Record<string, number>;
  handOver?: boolean;
  winnerSeat?: 0 | 1 | null; // null = Split Pot
}

const other = (seat: 0 | 1): 0 | 1 => (seat === 0 ? 1 : 0);

/** Deckt die nächsten n Karten vom Deck auf (kein Burn-Card — bewusste
 * Vereinfachung für den Prototyp, siehe Verifikationsplan). */
function dealCards(deck: string[], n: number): { cards: string[]; rest: string[] } {
  return { cards: deck.slice(0, n), rest: deck.slice(n) };
}

function nextStreetCardCount(phase: Phase): number {
  if (phase === 'preflop') return 3; // Flop
  if (phase === 'flop') return 1;    // Turn
  if (phase === 'turn') return 1;    // River
  return 0;
}

function nextStreetName(phase: Phase): Phase {
  if (phase === 'preflop') return 'flop';
  if (phase === 'flop') return 'turn';
  if (phase === 'turn') return 'river';
  return 'showdown';
}

/**
 * Reine Funktion: nimmt den aktuellen Zustand + eine Aktion, gibt den
 * neuen Zustand zurück. Macht KEINE DB-Zugriffe — darum problemlos mit
 * Node testbar, ohne Deno oder eine echte Datenbank zu brauchen.
 */
export function applyAction(
  state: HandState,
  seats: Record<string, SeatInfo>,
  actingSeat: 0 | 1,
  action: ActionType,
  amount?: number,
): ApplyActionResult {
  if (!['preflop', 'flop', 'turn', 'river'].includes(state.phase)) {
    return { error: 'not_betting_phase' };
  }
  if (state.current_seat !== actingSeat) {
    return { error: 'not_your_turn' };
  }

  const opp = other(actingSeat);
  const bets = { ...state.bets };
  const acted = { ...state.acted };
  const folded = { ...state.folded };
  const stacks = { [actingSeat]: seats[actingSeat].stack, [opp]: seats[opp].stack };
  let pot = state.pot;
  let lastRaiseSize = state.last_raise_size;

  const toCall = (bets[opp] || 0) - (bets[actingSeat] || 0);

  if (action === 'fold') {
    folded[actingSeat] = true;
  } else if (action === 'check') {
    if (toCall !== 0) return { error: 'cannot_check_facing_bet' };
    acted[actingSeat] = true;
  } else if (action === 'call') {
    if (toCall <= 0) return { error: 'nothing_to_call' };
    const callAmt = Math.min(toCall, stacks[actingSeat]);
    bets[actingSeat] = (bets[actingSeat] || 0) + callAmt;
    stacks[actingSeat] -= callAmt;
    pot += callAmt;
    acted[actingSeat] = true;
  } else if (action === 'bet' || action === 'raise') {
    if (typeof amount !== 'number' || !Number.isFinite(amount)) return { error: 'invalid_amount' };
    const currentBet = bets[actingSeat] || 0;
    if (amount <= currentBet) return { error: 'invalid_amount' };
    const added = amount - currentBet;
    if (added > stacks[actingSeat]) return { error: 'insufficient_stack' };
    const isAllIn = added === stacks[actingSeat];
    const minTotal = (bets[opp] || 0) + lastRaiseSize;
    if (amount < minTotal && !isAllIn) return { error: 'raise_too_small' };
    const raiseSize = amount - (bets[opp] || 0);
    bets[actingSeat] = amount;
    stacks[actingSeat] -= added;
    pot += added;
    acted[actingSeat] = true;
    acted[opp] = false; // Gegner muss auf die neue Erhöhung reagieren
    if (raiseSize > lastRaiseSize) lastRaiseSize = raiseSize;
  } else {
    return { error: 'unknown_action' };
  }

  // Hand endet sofort durch Fold
  if (folded[actingSeat]) {
    return {
      state: { ...state, bets, acted, folded, pot, last_raise_size: lastRaiseSize, phase: 'done', current_seat: opp },
      stacks,
      handOver: true,
      winnerSeat: opp,
    };
  }

  const bothActed = !!acted[0] && !!acted[1];
  const betsEqual = (bets[0] || 0) === (bets[1] || 0);
  const roundComplete = bothActed && betsEqual;
  const someoneAllIn = stacks[0] === 0 || stacks[1] === 0;

  if (!roundComplete) {
    return {
      state: { ...state, bets, acted, folded, pot, last_raise_size: lastRaiseSize, current_seat: opp },
      stacks,
      handOver: false,
    };
  }

  // Setzrunde fertig
  if (state.phase === 'river' || someoneAllIn) {
    // Restliche Board-Karten (falls All-in vor dem River) aufdecken, dann Showdown.
    let board = state.board.slice();
    let deck = state.deck.slice();
    let phase: Phase = state.phase;
    while (phase !== 'river' && phase !== 'showdown') {
      const n = nextStreetCardCount(phase);
      const { cards, rest } = dealCards(deck, n);
      board = board.concat(cards);
      deck = rest;
      phase = nextStreetName(phase);
    }
    return {
      state: { ...state, bets, acted, folded, pot, last_raise_size: lastRaiseSize, board, deck, phase: 'showdown', current_seat: actingSeat },
      stacks,
      handOver: false, // resolveShowdown() entscheidet den Gewinner separat
    };
  }

  // Nächste Strasse: Karten aufdecken, Einsätze zurücksetzen, Nicht-Dealer beginnt.
  const { cards, rest } = dealCards(state.deck, nextStreetCardCount(state.phase));
  const newPhase = nextStreetName(state.phase);
  const firstToAct = other(state.dealer_seat); // Heads-up: Nicht-Dealer (Big Blind) agiert postflop zuerst
  return {
    state: {
      ...state,
      bets: { 0: 0, 1: 0 },
      acted: {},
      folded,
      pot,
      last_raise_size: state.pot > 0 ? state.last_raise_size : lastRaiseSize, // Big-Blind-Grösse bleibt Minimum
      board: state.board.concat(cards),
      deck: rest,
      phase: newPhase,
      current_seat: firstToAct,
    },
    stacks,
    handOver: false,
  };
}

/** Showdown: vergleicht beide Hände, gibt den Sitz des Gewinners zurück
 * (oder null bei Split Pot). */
export function resolveShowdown(holeCards: Record<string, string[]>, board: string[]): { winnerSeat: 0 | 1 | null; values: Record<string, number[]> } {
  const val0 = evaluate7(holeCards[0].concat(board));
  const val1 = evaluate7(holeCards[1].concat(board));
  const cmp = compareHandArrays(val0, val1);
  return { winnerSeat: cmp === 0 ? null : cmp > 0 ? 0 : 1, values: { 0: val0, 1: val1 } };
}
