# zkLLM: Zero Knowledge Proofs for Large Language Models

Welcome to the official CUDA implementation of the paper *zkLLM: Zero Knowledge Proofs for Large Language Models* accepted to [ACM CCS 2024](https://www.sigsac.org/ccs/CCS2024/home.html), authored by [Haochen Sun](https://cs.uwaterloo.ca/~h299sun/), Jason Li, and [Hongyang Zhang](https://hongyanz.github.io/) from the University of Waterloo. The long version of the paper is [available on arXiv](https://arxiv.org/abs/2404.16109).

*Note: This repository is subject to occasional updates to incorporate better designs and hyperparameters.*

## Updates

- **[2024-05-17]** Implemented enhancements to align the open-sourced version with both the original, pre-refinement codebase and the original LLaMa-2 model.

## Open-Sourcing Progress

Our open-sourcing process includes:
- [x] The wheel of tensors over the `BLS12-381` elliptic curve.
- [x] Implementation of `tlookup` and `zkAttn`, two major technical components of *zkLLM*.
- [x] The proof of the entire inference process.
- [ ] Work in progress: The seperation the computation and the interactive proof in the demo. 

## Disclaimers

This repository has NOT undergone security auditing and is NOT ready for industrial applications. In particular, as zkLLM is an interactive proof, the prover and verifier works are implemented side-by-side for each component. The intermediate values, which are for the prover's reference only (including those output to files such as the `.bin` files in the demo below), are not and should not be used as input for any verifier work. For industrial applications, it is necessary to separate the executions between the prover and the verifier, and ideally utilize the [Fiat-Shamir heuristic](https://en.wikipedia.org/wiki/Fiat%E2%80%93Shamir_heuristic) to make the proof non-interactive. This would require a systematic re-design of the entire system.

While Haochen welcomes your questions and comments **(see his contact methods [here](https://cs.uwaterloo.ca/~h299sun/#contact)!)**, please understand that he is working on his own new research projects and is unable to provide extensive support. In particular, it is inappropriate to expect or attempt to engage him in voluntary work on projects that primarily serve others’ financial interests.

## Requirements and Setup

zkLLM is implemented in CUDA. We recommend using CUDA 12.1.0, installed within a `conda` virtual environment. To set up the environment:

```bash
conda create -n zkllm-env python=3.11
conda activate zkllm-env 
conda install cuda -c nvidia/label/cuda-12.1.0
```

Also, to load the LLMs and run the experiments, you will need `torch`, `transformers` and `datasets`:

```bash
pip install torch torchvision torchaudio transformers datasets
```

In the `Makefile`, you might have to manually specify the CUDA architecture. For instance, for an NVIDIA RTX A6000, you should assign `sm_86` to `ARCH`.

## An Example with LLaMa-2

The following serves as an example for LLaMa-2. Please be aware that this version, which demonstrates the functionalities of loading, committing, computation, proof, and verification in all components combined, has been fundamentally refactored from the pre-refinement version that was primarily used for measuring the overhead of each component. Also, note that the details for other models may vary.

First, download the models ([`meta-llama/Llama-2-7b-hf`](https://huggingface.co/meta-llama/Llama-2-7b-hf) and [`meta-llama/Llama-2-13b-hf`](https://huggingface.co/meta-llama/Llama-2-13b-hf)) from Hugging Face using `download-models.py`. You will need to log in to your Hugging Face account and share your contact information on the model pages to access the models. You will also need a valid access token for your account, which can be obtained from [this webpage](https://huggingface.co/settings/tokens) by generating a new token. Make sure to choose `Read` as the token type. Your token should look like this: `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` (note that this token has been deactivated and cannot be used). Then, run the following commands to download the models:

```bash 
# replace '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' with your own token
python download-models.py meta-llama/Llama-2-7b-hf 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
python download-models.py meta-llama/Llama-2-13b-hf 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
```

Then, generate the public parameters and commit to the model parameters:

```bash
model_size=7 # 7 or 13 (billions of parameters)
python llama-ppgen.py $model_size
python llama-commit.py $model_size 16 # the default scaling factor is (1 << 16). Others have not been tested.
```

Here, `llama-ppgen.py` generates the public parameters used in the commitment scheme. Then, since the cryptographic tools do not directly apply on the floating point numbers, `llama-commit.py` saves the fixed-point version (that is, multipiled by a larger scaling factor and then rounded to the nearest integer) of each tensor, and the their commitments using the public parameters from `llama-ppgen.py`.

Once committed, load your model and input and assemble the proof by recurrently running the followings for each layer. For understanding the format of `.bin` files that store tensors in fixed-point formats (i.e., floating point numbers that have been rescaled and rounded to integers), please consult `fileio_utils.py`.

```bash
input=layer_input.bin
attn_input=attn_input.bin
attn_output=attn_output.bin
post_attn_norm_input=post_attn_norm_input.bin
ffn_input=ffn_input.bin
ffn_output=ffn_output.bin
output=layer_output.bin

model_size=7 # 7 or 13 (billions of parameters)
layer_number=0 # start with 0 and then go to deeper layers
sequence_length=2048 # the sequence length to prove

python llama-rmsnorm.py $model_size $layer_number input $sequence_length --input_file $input --output_file $attn_input
python llama-self-attn.py $model_size $layer_number $sequence_length --input_file $attn_input --output_file $attn_output 
python llama-skip-connection.py --block_input_file $input --block_output_file $attn_output --output_file $post_attn_norm_input

python llama-rmsnorm.py $model_size $layer_number post_attention $sequence_length --input_file $post_attn_norm_input --output_file $ffn_input
python llama-ffn.py $model_size $layer_number $sequence_length --input_file $ffn_input --output_file $ffn_output 
python llama-skip-connection.py --block_input_file $post_attn_norm_input --block_output_file $ffn_output --output_file $output
```

Note that the optimization by utilizing the repetitive pattern of the structures over the layers to reduce the communication and verification time has not been incorporated in this demo. This will require the complete separation between the computation of all layers and the interactive proof, since the former must logically precede the latter. Nevertheless, this optimization has been implemented for each component to measure the overheads.

## Contacts

For any questions, comments, or discussions regarding potential collaborations, please feel free to [contact Haochen Sun](https://cs.uwaterloo.ca/~h299sun/#contact).


## Acknowledgements

zkLLM utilizes the CUDA implementation of BS12-381 curve, [`ec-gpu`](https://github.com/filecoin-project/ec-gpu), developed by [Filecoin](https://filecoin.io/). We extend our gratitude to Tonghe Bai and Andre Slavecu, both from University of Waterloo, for their contributions during the early stages of codebase development.
