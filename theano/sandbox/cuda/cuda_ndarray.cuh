#ifndef _CUDA_NDARRAY_H
#define _CUDA_NDARRAY_H

#include <numpy/arrayobject.h>
#include <stdio.h>

#include <cublas.h>

typedef float real;
#define REAL_TYPENUM 11

#ifdef __DEVICE_EMULATION__
#define NUM_VECTOR_OP_BLOCKS                4096
#define NUM_VECTOR_OP_THREADS_PER_BLOCK     1  //This prevents printf from getting tangled up
#else
#define NUM_VECTOR_OP_BLOCKS                4096 //Max number of blocks to launch.  Should be read from device properties. (#10)
#define NUM_VECTOR_OP_THREADS_PER_BLOCK     256  //Should be read from device properties. (#10)
#endif

#if 0
// Do not wait after every kernel & transfer.
#define CNDA_THREAD_SYNC
#else
// This is useful for using normal profiling tools
#define CNDA_THREAD_SYNC cudaThreadSynchronize();
#endif


/**
 * struct CudaNdarray
 *
 * This is a Python type.  
 *
 */
struct CudaNdarray 
{
    PyObject_HEAD

    /**
     * base:
     *  either NULL or a pointer to a fellow CudaNdarray into which this one is viewing.
     *  This pointer is never followed, except during Py_DECREF when we do not need it any longer.
     */
    PyObject * base;

    /* Type-specific fields go here. */
    //GpuTensorType::VoidTensor * vt;
    int nd; //the number of dimensions of the tensor
    int * host_structure; //dim0, dim1, ... stride0, stride1, ...
    int data_allocated; //the number of bytes allocated for devdata

    //device pointers (allocated by cudaMalloc)
    int dev_structure_fresh;
    int * dev_structure; //dim0, dim1, ..., stride0, stride1, ...
    real* devdata; //pointer to data element [0,..,0].
};

/*
 * Return a CudaNdarray whose 'nd' dimensions are all 0.
 */
PyObject * 
CudaNdarray_New(int nd);

/**
 * Return 1 for a CudaNdarray otw 0
 */
int 
CudaNdarray_Check(const PyObject * ob);

/**
 * Return 1 for a CudaNdarray otw 0
 */
int 
CudaNdarray_CheckExact(const PyObject * ob);

/****
 * Returns the number of elements necessary in host_structure and dev_structure for a given number of dimensions.
 */
int 
cnda_structure_size(int nd)
{
    // dim0, dim1, ...
    // str0, str1, ...
    // log2(dim0), log2(dim1), ...
    return nd + nd + nd;
}

const int * 
CudaNdarray_HOST_DIMS(const CudaNdarray * self)
{
    return self->host_structure;
}
const int * 
CudaNdarray_HOST_STRIDES(const CudaNdarray * self)
{
    return self->host_structure + self->nd;
}
const int * 
CudaNdarray_HOST_LOG2DIMS(const CudaNdarray * self)
{
    return self->host_structure + 2*self->nd;
}

void 
cnda_mark_dev_structure_dirty(CudaNdarray * self)
{
    self->dev_structure_fresh = 0;
}
/****
 *  Set the idx'th dimension to value d.
 *
 *  Updates the log2dim shaddow array.
 *
 *  Does not sync structure to host.
 */
void 
CudaNdarray_set_dim(CudaNdarray * self, int idx, int d)
{
    if ((idx >= self->nd) || (idx < 0) || (d < 0))
    {
        fprintf(stderr, "WARNING: probably bad CudaNdarray_set_dim arguments: %i %i\n", idx, d);
    }

    if (d != self->host_structure[idx])
    {
        self->host_structure[idx] = d;
        int log2d = (int)log2((double)d);
        self->host_structure[idx + 2*self->nd] = (d == (1 << log2d)) ? log2d : -1;
        cnda_mark_dev_structure_dirty(self);
    }
}
void 
CudaNdarray_set_stride(CudaNdarray * self, int idx, int s)
{
    if ((idx >= self->nd) || (idx < 0))
    {
        fprintf(stderr, "WARNING: probably bad CudaNdarray_set_stride arguments: %i %i\n", idx, s);
    }

    if (s != CudaNdarray_HOST_STRIDES(self)[idx])
    {
        self->host_structure[idx+self->nd] = s;
        cnda_mark_dev_structure_dirty(self);
    }
}
/***
 *  Update dependent variables from the contents of CudaNdarray_HOST_DIMS(self) and CudaNdarray_HOST_STRIDES(self)
 *
 *  This means: recalculate the log2dims and transfer structure to the card
 */
int 
cnda_copy_structure_to_device(CudaNdarray * self)
{
    cublasSetVector(cnda_structure_size(self->nd), sizeof(int), self->host_structure, 1, self->dev_structure, 1);
    CNDA_THREAD_SYNC;
    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error copying structure to device memory");
        return -1;
    }
    self->dev_structure_fresh = 1;
    return 0;
}

const int * 
CudaNdarray_DEV_DIMS(CudaNdarray * self)
{
    if (!self->dev_structure_fresh)
    {
        if (cnda_copy_structure_to_device(self))
            return NULL;
    }
    return self->dev_structure;
}
const int * 
CudaNdarray_DEV_STRIDES(CudaNdarray * self)
{
    if (!self->dev_structure_fresh)
    {
        if (cnda_copy_structure_to_device(self))
            return NULL;
    }
    return self->dev_structure + self->nd;
}
const int * 
CudaNdarray_DEV_LOG2DIMS(CudaNdarray * self)
{
    if (!self->dev_structure_fresh)
    {
        if (cnda_copy_structure_to_device(self))
            return NULL;
    }
    return self->dev_structure + 2*self->nd;
}
float * 
CudaNdarray_DEV_DATA(const CudaNdarray * self)
{
    return self->devdata;
}

/**
 * Return the number of elements in the ndarray (product of the dimensions)
 */
int 
CudaNdarray_SIZE(const CudaNdarray *self)
{
    if (self->nd == -1) return 0;
    int size = 1;
    for (int i = 0; i < self->nd; ++i)
    {
        size *= CudaNdarray_HOST_DIMS(self)[i];
    }
    return size;
}



/**
 * Allocate a new CudaNdarray with nd==-1
 */
PyObject * CudaNdarray_new_null();

/**
 * Allocate a new CudaNdarray with room for given number of dimensions
 *
 * No Storage space is allocated (and all dimensions are 0)
 */
PyObject * CudaNdarray_new_nd(const int nd);

/**
 * [Re]allocate a CudaNdarray with access to 'nd' dimensions.
 *
 * Note: This does not allocate storage for data.
 */
int CudaNdarray_set_nd(CudaNdarray * self, const int nd)
{
    if (nd != self->nd)
    {
        if (self->dev_structure)
        {
            cublasFree(self->dev_structure);
            if (CUBLAS_STATUS_SUCCESS != cublasGetError())
            {
                PyErr_SetString(PyExc_MemoryError, "error freeing device memory");
                return -1;
            }
            self->dev_structure = NULL;
        }
        if (self->host_structure) 
        {
            free(self->host_structure);
            self->host_structure = NULL;
            self->nd = -1;
        }
        if (nd == -1) return 0;

        self->host_structure = (int*)malloc(cnda_structure_size(nd)*sizeof(int));
        //initialize all dimensions and strides to 0
        for (int i = 0; i < cnda_structure_size(nd); ++i) self->host_structure[i] = 0;
        if (NULL == self->host_structure)
        {
            PyErr_SetString(PyExc_MemoryError, "Failed to allocate dim or str");
            return -1;
        }
        cublasAlloc(cnda_structure_size(nd), sizeof(int), (void**)&self->dev_structure);
        if (CUBLAS_STATUS_SUCCESS != cublasGetError())
        {
            PyErr_SetString(PyExc_MemoryError, "error allocating device memory");
            free(self->host_structure);
            self->host_structure = NULL;
            self->dev_structure = NULL;
            return -1;
        }
        self->nd = nd;
        self->dev_structure_fresh = 0;
    }
    return 0;
}

/**
 * CudaNdarray_alloc_contiguous
 *
 * Allocate storage space for a tensor of rank 'nd' and given dimensions.
 *
 * Note: CudaNdarray_alloc_contiguous is templated to work for both int dimensions and npy_intp dimensions
 */
template<typename inttype>
int CudaNdarray_alloc_contiguous(CudaNdarray *self, const int nd, const inttype * dim)
{
    // allocate an empty ndarray with c_contiguous access
    // return 0 on success
    int size = 1; //set up the strides for contiguous tensor
    assert (nd >= 0);
    if (CudaNdarray_set_nd(self, nd))
    {
        return -1;
    }
    //TODO: check if by any chance our current dims are correct,
    //      and strides already contiguous
    //      in that case we can return right here.
    for (int i = nd-1; i >= 0; --i)
    {
        CudaNdarray_set_stride(self, i, (dim[i] == 1) ? 0 : size);
        CudaNdarray_set_dim(self, i, dim[i]);
        size = size * dim[i];
    }

    if (self->data_allocated != size)
    {
        //std::cerr << "resizing from  " << self->data_allocated << " to " << size << '\n';
        cublasFree(self->devdata);
        if (CUBLAS_STATUS_SUCCESS != cublasGetError())
        {// Does this ever happen??  Do we need to set data_allocated or devdata to 0?
            PyErr_SetString(PyExc_MemoryError, "error freeing device memory");
            return -1;
        }
        assert(size>0);
        cublasAlloc(size, sizeof(real), (void**)&(self->devdata));
        //std::cerr << "cublasAlloc returned " << self->devdata << "\n";
        //We must do both checks as the first one is not enough in some cases!
        if (CUBLAS_STATUS_SUCCESS != cublasGetError() || !self->devdata)
        {
            PyErr_Format(PyExc_MemoryError, "error allocating %i bytes device memory",size);
            CudaNdarray_set_nd(self,-1);
            self->data_allocated = 0;
            self->devdata = 0;
            return -1;
        }
        self->data_allocated = size;
    }
    return 0;
}

/*
 * Return a CudaNdarray whose 'nd' dimensions are set to dims, and allocated.
 */
template<typename inttype>
PyObject * 
CudaNdarray_NewDims(int nd, const inttype * dims)
{
    CudaNdarray * rval = (CudaNdarray*)CudaNdarray_new_null();
    if (rval)
    {
        if (CudaNdarray_alloc_contiguous(rval, nd, dims))
        {
            Py_DECREF(rval);
            return NULL;
        }
    }
    return (PyObject*)rval;
}


/**
 * CudaNdarray_set_device_data
 *
 * Set self to be a view of given `data`, owned by existing CudaNdarray `base`.
 */
int CudaNdarray_set_device_data(CudaNdarray * self, float * data, CudaNdarray * base);

/**
 * Return an independent copy of self
 */
PyObject * CudaNdarray_DeepCopy(CudaNdarray * self, PyObject * memo);

/**
 * Return an independent copy of self
 */
PyObject * CudaNdarray_Copy(CudaNdarray * self);

/**
 * Return a new object obtained by summing over the dimensions for which there is a 1 in the mask.
 */
PyObject * CudaNdarray_ReduceSum(CudaNdarray * self, PyObject * py_reduce_mask);

/**
 * Transfer the contents of numpy array `obj` to `self`.
 *
 * self is reallocated to have the correct dimensions if necessary.
 */
int CudaNdarray_CopyFromArray(CudaNdarray * self, PyArrayObject*obj);

/**
 * Transfer the contents of CudaNdarray `other` to `self`.
 *
 * self is reallocated to have the correct dimensions if necessary.
 */
int CudaNdarray_CopyFromCudaNdarray(CudaNdarray * self, CudaNdarray * other);

/**
 * Transfer the contents of CudaNdarray `self` to a new numpy ndarray.
 */
PyObject * 
CudaNdarray_CreateArrayObj(CudaNdarray * self);

/**
 * True iff the strides look like [dim[nd-2], dim[nd-3], ... , dim[0], 1]
 */
bool CudaNdarray_is_c_contiguous(const CudaNdarray * self);

int CudaNdarray_gemm(float alpha, const CudaNdarray * A, const CudaNdarray * B, float beta, CudaNdarray * C);


int CudaNdarray_reduce_sum(CudaNdarray * self, CudaNdarray * A);
int CudaNdarray_reduce_prod(CudaNdarray * self, CudaNdarray * A);
int CudaNdarray_reduce_min(CudaNdarray * self, CudaNdarray * A);
int CudaNdarray_reduce_max(CudaNdarray * self, CudaNdarray * A);

int CudaNdarray_dimshuffle(CudaNdarray * self, unsigned int len, const int * pattern);

enum { ConvMode_FULL, ConvMode_VALID };
PyObject * CudaNdarray_Conv(const CudaNdarray *img, const CudaNdarray * kern, CudaNdarray * out, const int mode, const int subsample_rows, const int subsample_cols, const int version, const int verbose);
PyObject * CudaNdarray_Conv(const CudaNdarray *img, const CudaNdarray * kern, CudaNdarray * out, const int mode)
{
    return CudaNdarray_Conv(img, kern, out, mode, 1, 1, -1, 0);
}
int CudaNdarray_conv(const CudaNdarray *img, const CudaNdarray * kern, CudaNdarray * out, const int mode);

void fprint_CudaNdarray(FILE * fd, const CudaNdarray *self)
{
    fprintf(fd, "CudaNdarray <%p, %p> nd=%i \n", self, self->devdata, self->nd);
    fprintf(fd, "\tHOST_DIMS:      ");
    for (int i = 0; i < self->nd; ++i)
    {
        fprintf(fd, "%i\t", CudaNdarray_HOST_DIMS(self)[i]);
    }
    fprintf(fd, "\n\tHOST_STRIDES: ");
    for (int i = 0; i < self->nd; ++i)
    {
        fprintf(fd, "%i\t", CudaNdarray_HOST_STRIDES(self)[i]);
    }
    fprintf(fd, "\n");
}

#endif