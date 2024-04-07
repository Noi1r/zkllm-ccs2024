#include "commitment.cuh"

KERNEL void com_sum_row_kernel(const G1Jacobian_t* arr, G1Jacobian_t* arr_out, uint m, uint n) {
    auto row = GET_GLOBAL_ID();
    if (row < m) {
        G1Jacobian_t rowSum = arr[row * n];
        for (uint i = 1; i < n; ++ i) {
            rowSum = blstrs__g1__G1Affine_add(rowSum, arr[row * n + i]);
        }
        arr_out[row] = rowSum;
    }
    
}

G1Jacobian_t Commitment::commit(const FrTensor& t) const
{
    if (t.size % size != 0) throw std::runtime_error("Commitment::commit - Incompatible dimensions");

    uint m = t.size / size;
    G1TensorJacobian temp = (*this) * t;
    return temp.sum();
}


DEVICE G1Jacobian_t commit_int_dev_func(G1Jacobian_t a, Fr_t s) {
    const int x = scalar_to_int(s);
    G1Jacobian_t out = blstrs__g1__G1Affine_ZERO;
    #pragma unroll
    for (uint i = 0; i < 31; ++ i) {
        if ((x >> i) & 1) out = blstrs__g1__G1Affine_add(out, a);
        a = blstrs__g1__G1Affine_double(a);
    }
    
    if (x < 0) out = blstrs__g1__G1Affine_add(out, G1Jacobian_minus(a));
    return out;
}

KERNEL void commit_int_kernel(const G1Jacobian_t* generators, const Fr_t* scalars, G1Jacobian_t* out, uint n, uint m) {
    const uint gid = GET_GLOBAL_ID();
    if (gid >= m * n) return;
    out[gid] = commit_int_dev_func(generators[gid % n], scalars[gid]);
}

G1Jacobian_t Commitment::commit_int (const FrTensor& t) const{
    if (t.size % size != 0) throw std::runtime_error("Commitment::commit_int - Incompatible dimensions");

    uint m = t.size / size;
    G1TensorJacobian temp(t.size);
    commit_int_kernel<<<(m*size+G1NumThread-1)/G1NumThread,G1NumThread>>>(gpu_data, t.gpu_data, temp.gpu_data, size, m);
    cudaDeviceSynchronize();
    return temp.sum();
}


G1Jacobian_t Commitment::commit_int_multi(const vector<FrTensor>& ts) const{
    uint num_row = 0;
    for (auto& t : ts) {
        if (t.size % size != 0) throw std::runtime_error("Commitment::commit_int_multi - Incompatible dimensions");
        num_row += t.size / size;
    }

    G1TensorJacobian temp(num_row * size);
    auto temp_start = temp.gpu_data;
    for (auto& t: ts)
    {
        uint m = t.size / size;
        commit_int_kernel<<<(m*size+G1NumThread-1)/G1NumThread,G1NumThread>>>(gpu_data, t.gpu_data, temp_start, size, m);
        cudaDeviceSynchronize();
        temp_start += m * size;
    }
    return temp.sum();
}

KERNEL void me_open_step(GLOBAL Fr_t* scalars, GLOBAL G1Jacobian_t* generators, Fr_t u, // always assume that scalars and u is in mont form
    GLOBAL Fr_t* new_scalars, GLOBAL G1Jacobian_t* new_generators,
    GLOBAL G1Jacobian_t* temp_out, GLOBAL G1Jacobian_t* temp_out0, GLOBAL G1Jacobian_t* temp_out1, 
    uint new_size) // always assume that old size is even, as will be implemented
{
    const uint gid = GET_GLOBAL_ID();
    if (gid >= new_size) return;

    uint gid0 = 2 * gid;
    uint gid1 = 2 * gid + 1;

    Fr_t u_unmont = blstrs__scalar__Scalar_unmont(u);
    new_scalars[gid] = blstrs__scalar__Scalar_add(scalars[gid0], blstrs__scalar__Scalar_mul(u, blstrs__scalar__Scalar_sub(scalars[gid1], scalars[gid0])));
    new_generators[gid] = blstrs__g1__G1Affine_add(generators[gid1], G1Jacobian_mul(blstrs__g1__G1Affine_add(generators[gid0], G1Jacobian_minus(generators[gid1])), u_unmont));
    temp_out[gid] = blstrs__g1__G1Affine_add(G1Jacobian_mul(generators[gid0], scalars[gid0]), G1Jacobian_mul(generators[gid1], scalars[gid1]));
    temp_out0[gid] = G1Jacobian_mul(generators[gid1], scalars[gid0]);
    temp_out1[gid] = G1Jacobian_mul(generators[gid0], scalars[gid1]);
}

Fr_t Commitment::me_open(const FrTensor& t, const Commitment& generators, vector<Fr_t>::const_iterator begin, vector<Fr_t>::const_iterator end, vector<G1Jacobian_t>& proof)
{
    if (t.size != generators.size) throw std::runtime_error("Incompatible dimensions");
    if (begin >= end)
    {
        proof.push_back(generators(0));
        return t(0);
    }
    uint new_size = t.size / 2;
    FrTensor new_scalars(new_size);
    Commitment new_generators(new_size);
    G1TensorJacobian temp(new_size), temp0(new_size), temp1(new_size);
    me_open_step<<<(new_size+G1NumThread-1)/G1NumThread,G1NumThread>>>(t.gpu_data, generators.gpu_data, *begin, 
    new_scalars.gpu_data, new_generators.gpu_data, temp.gpu_data, temp0.gpu_data, temp1.gpu_data, new_size);
    cudaDeviceSynchronize();
    proof.push_back(temp.sum());
    proof.push_back(temp0.sum());
    proof.push_back(temp1.sum());
    return me_open(new_scalars, new_generators, begin + 1, end, proof);
}

Commitment Commitment::random(uint size)
{
    Commitment out(size, G1Jacobian_generator);
    out *= FrTensor::random(size);
    return out; 
}

Fr_t Commitment::open(const FrTensor& t, const G1TensorJacobian& com, const vector<Fr_t>& u) const
{
    const vector<Fr_t> u_out(u.end() - ceilLog2(com.size), u.end());
    const vector<Fr_t> u_in(u.begin(), u.end() - ceilLog2(com.size));

    auto g_temp = com(u_out);
    if (size != (1 << u_in.size())) throw std::runtime_error("Incompatible dimensions");
    vector<G1Jacobian_t> proof;
    return me_open(t.partial_me(u_out, 1 << u_in.size()), *this, u_in.begin(), u_in.end(), proof);
}