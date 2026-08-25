#!/usr/bin/env python3
"""Train Medusa speculative decoding heads for Gemma 4 E2B.

Each head is a lightweight ResBlock (Linear→SiLU→Linear + residual) that
predicts a future token from the model's last hidden state. The shared
lm_head (tied to embed_tokens) maps head output → vocab logits.

Usage:
    python train_medusa_heads.py \
        --model-path ./output/gemma4-e2b-final/hf_model \
        --output ./output/medusa_heads \
        --num-heads 3 \
        --num-samples 2000 \
        --epochs 5

On Mac Studio M4 Max 128GB: ~1-2 hours total.
"""

import argparse
import json
import os
import time

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, TensorDataset
from transformers import Gemma4ForConditionalGeneration, AutoTokenizer


class MedusaHead(nn.Module):
    """Single Medusa prediction head: ResBlock + shared lm_head."""

    def __init__(self, hidden_size: int):
        super().__init__()
        self.fc1 = nn.Linear(hidden_size, hidden_size, bias=False)
        self.fc2 = nn.Linear(hidden_size, hidden_size, bias=False)

    def forward(self, x):
        return self.fc2(F.silu(self.fc1(x))) + x  # residual connection


def collect_training_data(model, tokenizer, num_samples: int, seq_len: int = 512):
    """Collect (hidden_states, token_ids) pairs.

    Uses pre-built text prompts and runs a single forward pass (no autoregressive
    generation) to get hidden states. This is 10-50x faster than generating text.
    """
    print(f"Collecting training data: {num_samples} samples, seq_len={seq_len}...")

    # Diverse seed texts — long enough that tokenizing gives seq_len tokens.
    seed_texts = [
        "The history of artificial intelligence begins in the 1950s when Alan Turing proposed the famous Turing test as a measure of machine intelligence. Early AI research focused on symbolic reasoning and logic-based systems. The field experienced its first winter in the 1970s when funding dried up due to unmet expectations. Neural networks were revived in the 1980s with backpropagation, but the second AI winter followed. The modern deep learning era began around 2012 with AlexNet winning the ImageNet competition, demonstrating the power of convolutional neural networks trained on GPUs. Transformers, introduced in 2017 with the paper Attention Is All You Need, revolutionized natural language processing. Large language models like GPT and BERT showed that scaling up transformer models on massive text corpora could achieve remarkable capabilities.",
        "Quantum computing represents a fundamental shift in computational paradigms. Unlike classical bits that exist in states of 0 or 1, quantum bits or qubits can exist in superpositions of both states simultaneously. This property, along with entanglement and interference, allows quantum computers to solve certain problems exponentially faster than classical computers. Key algorithms include Shor's algorithm for factoring large numbers and Grover's algorithm for searching unsorted databases. Current quantum hardware faces challenges including decoherence, error rates, and the need for extremely low temperatures. Companies like IBM, Google, and startups are racing to build fault-tolerant quantum computers.",
        "Machine learning is a subset of artificial intelligence that enables systems to learn and improve from experience without being explicitly programmed. The field encompasses supervised learning where models learn from labeled data, unsupervised learning where models find patterns in unlabeled data, and reinforcement learning where agents learn through trial and error. Deep learning, using neural networks with many layers, has achieved breakthroughs in computer vision, natural language processing, speech recognition, and game playing. Transfer learning allows models trained on large datasets to be fine-tuned for specific tasks with limited data.",
        "The architecture of modern smartphones involves multiple specialized processors working in concert. The application processor handles general computing tasks, while dedicated neural engines accelerate machine learning inference. GPU cores handle graphics rendering and parallel computation. The modem processes cellular communications, and separate chips manage WiFi, Bluetooth, and other connectivity. Memory management is critical on mobile devices with limited RAM. The operating system must balance performance with battery life, thermal management, and user experience.",
        "Climate change is one of the most pressing challenges facing humanity. Rising global temperatures are caused primarily by greenhouse gas emissions from burning fossil fuels, deforestation, and industrial processes. Effects include rising sea levels, more frequent extreme weather events, disruptions to ecosystems and biodiversity, and threats to food security. Mitigation strategies include transitioning to renewable energy sources, improving energy efficiency, carbon capture technologies, and reforestation. Adaptation measures involve building resilient infrastructure, developing drought-resistant crops, and planning for population displacement.",
        "The evolution of programming languages reflects changing needs in software development. Assembly languages gave way to FORTRAN and COBOL in the 1950s. C introduced structured programming in the 1970s. Object-oriented languages like C++ and Java dominated the 1990s. Python's simplicity made it popular for scientific computing and machine learning. Rust addresses memory safety without garbage collection. Modern language design balances expressiveness, safety, performance, and developer productivity. Functional programming concepts from languages like Haskell have influenced mainstream languages.",
        "Neuroscience has made remarkable progress in understanding the brain. The human brain contains approximately 86 billion neurons connected by trillions of synapses. Techniques like fMRI, EEG, and optogenetics allow researchers to observe brain activity at various scales. Memory formation involves changes in synaptic strength through long-term potentiation. The prefrontal cortex plays a key role in executive function and decision-making. Neuroplasticity allows the brain to reorganize itself throughout life. Brain-computer interfaces are being developed to restore motor function and treat neurological disorders.",
        "Sustainable energy systems are crucial for addressing climate change while meeting growing global energy demand. Solar photovoltaic technology has seen dramatic cost reductions, making it competitive with fossil fuels in many markets. Wind energy, both onshore and offshore, continues to expand capacity worldwide. Energy storage technologies, particularly lithium-ion batteries, are essential for managing the intermittency of renewable sources. Smart grids use digital technology to optimize energy distribution. Hydrogen fuel cells offer potential for long-duration storage and heavy transport applications.",
        "The human immune system is a complex network of cells, tissues, and organs that work together to defend the body against pathogens. The innate immune system provides immediate but non-specific defense, while the adaptive immune system develops targeted responses to specific threats. T cells and B cells are key players in adaptive immunity, with B cells producing antibodies and T cells directly attacking infected cells. Vaccination trains the immune system to recognize pathogens without causing disease. Immunotherapy harnesses the immune system to fight cancer by removing the brakes that tumors use to evade detection.",
        "Space exploration has entered a new era with commercial companies playing an increasingly important role alongside government agencies. SpaceX's reusable rockets have dramatically reduced launch costs. Plans for returning humans to the Moon through NASA's Artemis program aim to establish a sustainable presence. Mars exploration continues with rovers and plans for crewed missions. The James Webb Space Telescope is revealing unprecedented views of the early universe. Satellite constellations are providing global internet coverage. The search for extraterrestrial life focuses on potentially habitable moons like Europa and Enceladus.",
    ]

    all_hidden = []
    all_tokens = []

    model.eval()
    with torch.no_grad():
        for i, text in enumerate(seed_texts):
            if len(all_hidden) >= num_samples:
                break
            # Repeat text to fill seq_len if needed
            ids = tokenizer.encode(text, return_tensors="pt", truncation=True,
                                     max_length=seq_len)
            if ids.shape[1] < 20:
                continue

            # Forward pass only (no generation!) — much faster
            outputs = model.model(
                input_ids=ids,
                output_hidden_states=False,
            )
            hidden = outputs.last_hidden_state[0].cpu().half()
            tokens = ids[0].cpu()
            all_hidden.append(hidden)
            all_tokens.append(tokens)

            if (i + 1) % 5 == 0:
                print(f"  {len(all_hidden)}/{num_samples} samples")

        # Load more data from HuggingFace datasets if we need more samples
        if len(all_hidden) < num_samples:
            try:
                from datasets import load_dataset
                print(f"  Loading wikitext for additional samples...")
                ds = load_dataset("wikitext", "wikitext-103-raw-v1", split="train",
                                  trust_remote_code=True)
                idx = 0
                for row in ds:
                    if len(all_hidden) >= num_samples:
                        break
                    text = row["text"].strip()
                    if len(text) < 100:
                        continue
                    ids = tokenizer.encode(text, return_tensors="pt",
                                           truncation=True, max_length=seq_len)
                    if ids.shape[1] < 30:
                        continue
                    outputs = model.model(input_ids=ids, output_hidden_states=False)
                    hidden = outputs.last_hidden_state[0].cpu().half()
                    all_hidden.append(hidden)
                    all_tokens.append(ids[0].cpu())
                    idx += 1
                    if idx % 100 == 0:
                        print(f"  {len(all_hidden)}/{num_samples} samples")
            except Exception as e:
                print(f"  Dataset loading failed: {e}, using seed texts only")

    print(f"  Total: {len(all_hidden)} samples, {sum(h.shape[0] for h in all_hidden)} tokens")
    return all_hidden, all_tokens


def build_training_pairs(all_hidden, all_tokens, num_heads: int,
                         lm_head_weight=None):
    """Build (input_hidden, target_tokens) pairs for each head.

    If lm_head_weight is provided, the TARGET for each position is the
    model's own argmax prediction (self-distillation), not the ground truth.
    This is critical: the Medusa head must predict what THIS model would
    output, not what the "correct" next token is.
    """
    inputs = []
    targets = [[] for _ in range(num_heads)]

    for hidden, tokens in zip(all_hidden, all_tokens):
        T = hidden.shape[0]
        max_pos = T - num_heads - 1
        if max_pos <= 0:
            continue

        inputs.append(hidden[:max_pos])

        if lm_head_weight is not None:
            # Self-distillation: use model's own predictions as targets
            with torch.no_grad():
                # hidden is fp16, lm_head is fp16 → compute in fp32 for stability
                logits = F.linear(hidden.float(), lm_head_weight.float())  # (T, vocab)
                model_preds = logits.argmax(dim=-1)  # (T,)
            for k in range(num_heads):
                targets[k].append(model_preds[k + 1 : k + 1 + max_pos])
        else:
            # Fallback: ground truth tokens
            for k in range(num_heads):
                targets[k].append(tokens[k + 1 : k + 1 + max_pos])

    all_inputs = torch.cat(inputs, dim=0)  # (N, hidden)
    all_targets = [torch.cat(t, dim=0) for t in targets]  # K × (N,)

    print(f"  Training pairs: {all_inputs.shape[0]} positions, {num_heads} heads")
    print(f"  Target type: {'self-distillation (model argmax)' if lm_head_weight is not None else 'ground truth'}")
    return all_inputs, all_targets


def train_heads(
    heads: nn.ModuleList,
    lm_head_weight: torch.Tensor,  # (vocab, hidden) — frozen
    train_inputs: torch.Tensor,
    train_targets: list,
    epochs: int = 5,
    batch_size: int = 64,
    lr: float = 1e-3,
):
    """Train all Medusa heads jointly."""
    num_heads = len(heads)
    # Exponential decay weights: head 0 (most important) → head 2 (least)
    head_weights = [1.0 / (2**k) for k in range(num_heads)]
    print(f"  Head loss weights: {head_weights}")

    dataset = TensorDataset(train_inputs, *train_targets)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=True, drop_last=True)

    optimizer = torch.optim.AdamW(heads.parameters(), lr=lr, weight_decay=0.01)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs * len(loader))

    # Move to device and ensure float32 for training
    device = train_inputs.device
    lm_head_weight = lm_head_weight.float().to(device)

    for epoch in range(epochs):
        total_loss = 0
        head_losses = [0.0] * num_heads
        n_batches = 0

        t0 = time.time()
        for batch in loader:
            hidden = batch[0].float()  # (B, hidden)
            target_list = [batch[k + 1] for k in range(num_heads)]  # K × (B,)

            loss = torch.tensor(0.0, device=device)
            for k, head in enumerate(heads):
                head_out = head(hidden)  # (B, hidden)
                # Apply shared lm_head: (B, hidden) × (hidden, vocab) → (B, vocab)
                logits = F.linear(head_out, lm_head_weight)  # (B, vocab)
                head_loss = F.cross_entropy(logits, target_list[k])
                loss = loss + head_weights[k] * head_loss
                head_losses[k] += head_loss.item()

            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(heads.parameters(), 1.0)
            optimizer.step()
            scheduler.step()

            total_loss += loss.item()
            n_batches += 1

        dt = time.time() - t0
        avg_loss = total_loss / n_batches
        per_head = [h / n_batches for h in head_losses]
        print(f"  Epoch {epoch+1}/{epochs}: loss={avg_loss:.4f}  "
              f"per_head={[f'{h:.4f}' for h in per_head]}  "
              f"lr={scheduler.get_last_lr()[0]:.6f}  {dt:.0f}s")
        head_losses = [0.0] * num_heads


def evaluate_acceptance(heads, lm_head_weight, test_hidden, test_tokens, num_heads):
    """Estimate draft acceptance rate."""
    print("\nEvaluating acceptance rate...")
    device = test_hidden.device
    lm_head_weight = lm_head_weight.float().to(device)

    correct = [0] * num_heads
    total = 0

    with torch.no_grad():
        # Process in chunks to avoid OOM
        chunk = 1024
        max_pos = test_hidden.shape[0] - num_heads - 1
        for start in range(0, max_pos, chunk):
            end = min(start + chunk, max_pos)
            hidden = test_hidden[start:end].float()

            for k, head in enumerate(heads):
                head_out = head(hidden)
                logits = F.linear(head_out, lm_head_weight)
                preds = logits.argmax(dim=-1)  # (chunk,)
                targets = test_tokens[start + k + 1 : end + k + 1]
                correct[k] += (preds == targets).sum().item()

            total += (end - start)

    rates = [c / total for c in correct]
    print(f"  Acceptance rates: {[f'{r:.1%}' for r in rates]}")
    avg_accepted = sum(r for r in rates)
    print(f"  Expected tokens per round: {1 + avg_accepted:.2f}")
    print(f"  Estimated speedup: {(1 + avg_accepted) / 1:.1f}x (idealized)")
    return rates


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", type=str,
                        default="./output/gemma4-e2b-final/hf_model")
    parser.add_argument("--output", type=str, default="./output/medusa_heads")
    parser.add_argument("--num-heads", type=int, default=3)
    parser.add_argument("--num-samples", type=int, default=2000,
                        help="Number of text sequences to generate for training data")
    parser.add_argument("--seq-len", type=int, default=256,
                        help="Max tokens per generated sequence")
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-3)
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)

    # Load model
    print(f"Loading model from {args.model_path}...")
    model = Gemma4ForConditionalGeneration.from_pretrained(
        args.model_path, torch_dtype=torch.float16, device_map="cpu"
    )
    model.eval()
    tokenizer = AutoTokenizer.from_pretrained(args.model_path)

    hidden_size = model.config.text_config.hidden_size
    print(f"  hidden_size={hidden_size}, vocab_size={model.config.text_config.vocab_size}")

    # Freeze base model
    for param in model.parameters():
        param.requires_grad = False

    # Create Medusa heads
    heads = nn.ModuleList([MedusaHead(hidden_size) for _ in range(args.num_heads)])
    total_params = sum(p.numel() for p in heads.parameters())
    print(f"  Medusa heads: {args.num_heads} heads, {total_params:,} params "
          f"({total_params * 2 / 1024 / 1024:.1f} MB fp16)")

    # Get shared lm_head weight before data collection (needed for self-distillation)
    lm_head_weight = model.lm_head.weight.data.clone().half()
    print(f"  lm_head weight: {lm_head_weight.shape}")

    # Collect training data
    all_hidden, all_tokens = collect_training_data(
        model, tokenizer, args.num_samples, args.seq_len
    )

    # Build training pairs (self-distillation: model's own argmax as target)
    train_inputs, train_targets = build_training_pairs(
        all_hidden, all_tokens, args.num_heads,
        lm_head_weight=lm_head_weight
    )

    # Split train/test (90/10)
    n = train_inputs.shape[0]
    split = int(n * 0.9)
    test_inputs = train_inputs[split:]
    test_targets_list = [t[split:] for t in train_targets]
    test_tokens_full = torch.cat(all_tokens)
    train_inputs = train_inputs[:split]
    train_targets = [t[:split] for t in train_targets]

    # Free the big model to save memory during training
    del model
    import gc; gc.collect()
    print("  Freed base model from memory")

    # Train
    print(f"\nTraining Medusa heads ({args.epochs} epochs, batch={args.batch_size})...")
    train_heads(heads, lm_head_weight, train_inputs, train_targets,
                epochs=args.epochs, batch_size=args.batch_size, lr=args.lr)

    # Evaluate
    evaluate_acceptance(heads, lm_head_weight, test_inputs,
                        torch.cat(all_tokens), args.num_heads)

    # Save
    print(f"\nSaving to {args.output}/...")
    save_dict = {"hidden_size": hidden_size, "num_heads": args.num_heads}
    for k, head in enumerate(heads):
        save_dict[f"head_{k}_fc1_weight"] = head.fc1.weight.data.half()
        save_dict[f"head_{k}_fc2_weight"] = head.fc2.weight.data.half()
    torch.save(save_dict, os.path.join(args.output, "medusa_heads.pt"))

    config = {
        "hidden_size": hidden_size,
        "num_heads": args.num_heads,
        "architecture": "resblock",
        "training_samples": args.num_samples,
        "training_epochs": args.epochs,
    }
    with open(os.path.join(args.output, "medusa_config.json"), "w") as f:
        json.dump(config, f, indent=2)

    size_mb = os.path.getsize(os.path.join(args.output, "medusa_heads.pt")) / 1024 / 1024
    print(f"  Saved medusa_heads.pt ({size_mb:.1f} MB)")
    print(f"  Saved medusa_config.json")
    print("\nDone! Next: convert to CoreML with convert_medusa_to_coreml.py")


if __name__ == "__main__":
    main()
