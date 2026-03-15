#!/usr/bin/env python3
# fmt: off
"""NNUE training script for mimir chess engine.

Architecture: 360 -> 128 -> 1
  Input:  30 squares x 12 piece types = 360 binary features
  Hidden: 128 neurons, ClippedReLU [0, 1]
  Output: 1 neuron (linear -> sigmoid for loss)

Usage: ../train output.nnue <data_files...>
"""

from struct import pack
from os import remove
from os.path import getsize
from sys import exit

import numpy as np
import torch

# Architecture constants
INPUT_SIZE = 360   # 30 squares x 12 piece types
HIDDEN_SIZE = 128
QA = 255           # feature layer quantization scale
QB = 64            # output layer quantization scale

# Piece char -> piece index (0-11)
PIECE_MAP = {
    'K': 0, 'Q': 1, 'N': 2, 'B': 3, 'R': 4, 'P': 5,
    'k': 6, 'q': 7, 'n': 8, 'b': 9, 'r': 10, 'p': 11,
}

# Mirror table: flips ranks for black perspective
MIRROR = [
    25, 26, 27, 28, 29,
    20, 21, 22, 23, 24,
    15, 16, 17, 18, 19,
    10, 11, 12, 13, 14,
     5,  6,  7,  8,  9,
     0,  1,  2,  3,  4,
]


def flip_piece(idx):
    """Swap white/black piece color: index 0-5 <-> 6-11."""
    return (idx + 6) % 12


def parse_position(line):
    """Parse a selfplay line into (feature_indices, score, stm_result).

    Format: <30char_board> <color> | <score> | <result>
    Score is STM-relative. Result is from white's perspective.
    """
    parts = line.strip().split(' | ')
    if len(parts) != 3:
        return None

    board_color = parts[0]
    if len(board_color) < 32:
        return None
    board = board_color[:30]
    color = board_color[31:].strip()

    try:
        score = int(parts[1])
        result = float(parts[2])
    except ValueError:
        return None

    # Filter mate/tablebase scores
    if abs(score) > 20000:
        return None

    is_black = color == 'black'

    # Result is white-relative; flip for black STM
    stm_result = (1.0 - result) if is_black else result

    # Encode features (always from STM perspective)
    features = []
    for sq in range(30):
        ch = board[sq]
        if ch == 'x':
            continue
        piece_idx = PIECE_MAP.get(ch)
        if piece_idx is None:
            continue

        if is_black:
            actual_sq = MIRROR[sq]
            piece_idx = flip_piece(piece_idx)
        else:
            actual_sq = sq

        features.append(actual_sq * 12 + piece_idx)

    return features, score, stm_result


class NNUEDataset(torch.utils.data.Dataset):
    def __init__(self, features, scores, results, lam=0.75):
        self.features = features
        self.scores = torch.tensor(scores, dtype=torch.float32)
        self.results = torch.tensor(results, dtype=torch.float32)
        self.lam = lam

    def __len__(self):
        return len(self.scores)

    def __getitem__(self, idx):
        # Build sparse input
        x = torch.zeros(INPUT_SIZE, dtype=torch.float32)
        for f in self.features[idx]:
            x[f] = 1.0

        # Target: blend of sigmoid(score/400) and game result
        score_sig = torch.sigmoid(self.scores[idx] / 400.0)
        target = self.lam * score_sig + (1 - self.lam) * self.results[idx]

        return x, target


class NNUE(torch.nn.Module):
    def __init__(self, hidden_size=HIDDEN_SIZE):
        super().__init__()
        self.hidden_size = hidden_size
        self.fc1 = torch.nn.Linear(INPUT_SIZE, hidden_size)
        self.fc2 = torch.nn.Linear(hidden_size, 1)

    def forward(self, x):
        x = self.fc1(x)
        x = torch.clamp(x, 0.0, 1.0)  # ClippedReLU
        x = self.fc2(x)
        return torch.sigmoid(x)


def load_data(files):
    """Load selfplay data from given files."""
    features = []
    scores = []
    results = []

    for f in files:
        count = 0
        with open(f) as fh:
            for line in fh:
                parsed = parse_position(line)
                if parsed is None:
                    continue
                feat, score, result = parsed
                features.append(feat)
                scores.append(score)
                results.append(result)
                count += 1
        print(f"  {f}: {count} positions")

    print(f"Total: {len(scores)} positions")
    return features, scores, results


def export_weights(model, path):
    """Export quantized weights to binary file.

    Binary format (little-endian):
      Header (16 bytes): magic "NNUE", version u8, input_size u16,
                          hidden_size u16, qa u16, qb u16, padding 3 bytes
      Feature weights: [360][128] i16  (feature-major)
      Feature biases:  [128] i16
      Output weights:  [128] i16
      Output bias:     i16
    """
    fc1_w = model.fc1.weight.detach().cpu().numpy()  # [128, 360]
    fc1_b = model.fc1.bias.detach().cpu().numpy()    # [128]
    fc2_w = model.fc2.weight.detach().cpu().numpy()  # [1, 128]
    fc2_b = model.fc2.bias.detach().cpu().numpy()    # [1]

    # Quantize feature layer by QA
    fw = np.clip(np.round(fc1_w * QA), -32767, 32767).astype(np.int16)  # [128, 360]
    fb = np.clip(np.round(fc1_b * QA), -32767, 32767).astype(np.int16)  # [128]

    # Quantize output layer by QB
    ow = np.clip(np.round(fc2_w[0] * QB), -32767, 32767).astype(np.int16)  # [128]

    # Output bias: scaled by QA * QB (undone by the final division)
    ob_val = int(np.clip(np.round(fc2_b[0] * QA * QB), -32767, 32767))

    with open(path, 'wb') as f:
        # Header (16 bytes)
        f.write(b'NNUE')                           # magic (4 bytes)
        f.write(pack('<B', 1))               # version (1 byte)
        f.write(pack('<H', INPUT_SIZE))      # input_size (2 bytes)
        f.write(pack('<H', model.hidden_size)) # hidden_size (2 bytes)
        f.write(pack('<H', QA))              # qa (2 bytes)
        f.write(pack('<H', QB))              # qb (2 bytes)
        f.write(b'\x00' * 3)                        # padding (3 bytes)

        # Feature weights: [360][128] i16, feature-major (transpose from [128, 360])
        fw_t = fw.T.copy()  # [360, 128], C-contiguous
        f.write(fw_t.tobytes())

        # Feature biases: [128] i16
        f.write(fb.tobytes())

        # Output weights: [128] i16
        f.write(ow.tobytes())

        # Output bias: i16
        f.write(pack('<h', ob_val))

    filesize = getsize(path)
    print(f"Exported {path} ({filesize} bytes)")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Train NNUE weights")
    parser.add_argument("output", help="Output weights file (e.g. mimir.nnue)")
    parser.add_argument("files", nargs="+", help="Selfplay data files")
    parser.add_argument("--lambda", dest="lam", type=float, default=0.75,
                        help="Blend factor: 1.0=pure score, 0.0=pure result (default: 0.75)")
    parser.add_argument("--hidden", type=int, default=128, help="Hidden layer size (default: 128)")
    parser.add_argument("--epochs", type=int, default=15, help="Training epochs (default: 15)")
    args = parser.parse_args()

    print("Loading data...")
    features, scores, results = load_data(args.files)

    if not scores:
        print("No data loaded!")
        exit(1)

    # Train/val split (5% holdout)
    n = len(scores)
    indices = np.random.permutation(n)
    val_size = n // 20
    val_idx = indices[:val_size]
    train_idx = indices[val_size:]

    print(f"Lambda: {args.lam} (score={args.lam:.0%}, result={1-args.lam:.0%})")

    train_ds = NNUEDataset(
        [features[i] for i in train_idx],
        [scores[i] for i in train_idx],
        [results[i] for i in train_idx],
        lam=args.lam,
    )
    val_ds = NNUEDataset(
        [features[i] for i in val_idx],
        [scores[i] for i in val_idx],
        [results[i] for i in val_idx],
        lam=args.lam,
    )

    train_dl = torch.utils.data.DataLoader(
        train_ds, batch_size=16384, shuffle=True,
        num_workers=4, pin_memory=torch.cuda.is_available(),
    )
    val_dl = torch.utils.data.DataLoader(
        val_ds, batch_size=16384,
        num_workers=4, pin_memory=torch.cuda.is_available(),
    )

    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"Device: {device}")
    print(f"Train: {len(train_ds)}, Val: {len(val_ds)}")

    model = NNUE(hidden_size=args.hidden).to(device)
    print(f"Architecture: {INPUT_SIZE} -> {args.hidden} -> 1")
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=args.epochs, eta_min=1e-4,
    )
    criterion = torch.nn.MSELoss()

    best_val_loss = float('inf')

    for epoch in range(args.epochs):
        # Train
        model.train()
        train_loss = 0.0
        train_batches = 0
        for x, target in train_dl:
            x = x.to(device)
            target = target.to(device).unsqueeze(1)

            pred = model(x)
            loss = criterion(pred, target)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            train_loss += loss.item()
            train_batches += 1

        scheduler.step()

        # Validate
        model.eval()
        val_loss = 0.0
        val_batches = 0
        with torch.no_grad():
            for x, target in val_dl:
                x = x.to(device)
                target = target.to(device).unsqueeze(1)
                pred = model(x)
                loss = criterion(pred, target)
                val_loss += loss.item()
                val_batches += 1

        avg_train = train_loss / max(train_batches, 1)
        avg_val = val_loss / max(val_batches, 1)
        lr = optimizer.param_groups[0]['lr']
        print(f"Epoch {epoch + 1:2d}/{args.epochs}  train={avg_train:.6f}  val={avg_val:.6f}  lr={lr:.6f}")

        if avg_val < best_val_loss:
            best_val_loss = avg_val
            torch.save(model.state_dict(), 'best_nnue.pt')

    # Load best model and export
    model.load_state_dict(torch.load('best_nnue.pt', weights_only=True))
    export_weights(model, args.output)
    remove('best_nnue.pt')
    print(f"Best val loss: {best_val_loss:.6f}")
    print("Done!")


if __name__ == '__main__':
    main()
