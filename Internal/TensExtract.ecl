IMPORT PYTHON3 as PYTHON;
IMPORT $.^ AS GNN;
IMPORT GNN.Tensor;
IMPORT Std.System.Thorlib;

nodeId := Thorlib.node();
nNodes := Thorlib.nodes();

t_Tensor := Tensor.R4.t_Tensor;

MAX_SLICE := Tensor.MAX_SLICE;

/**
  * This function is used by GNNI to pull local samples from the X and Y tensors.
  * The result is a new tensor with samples from each local slice of the tensor.
  * Note that this will extract datcount samples from EACH node.  The pos parameter
  * indicates how far into the local tensor slices to start extracting.
  */
EXPORT DATASET(t_Tensor) TensExtract(DATASET(t_Tensor) tens, UNSIGNED pos,
                                    UNSIGNED datcount) := FUNCTION
  // Python embed function to do most of the heavy lifting.
  STREAMED DATASET(t_Tensor) extract(STREAMED DATASET(t_Tensor) tens,
            UNSIGNED pos, UNSIGNED datcount, nodeid, maxslice) := EMBED(Python: activity)
    import numpy as np
    import traceback as tb
    try:
      maxSliceLen = maxslice
      dTypeDict = {1:np.float32, 2:np.float64, 3:np.int32, 4:np.int64}
      dTypeDictR = {'float32':1, 'float64':2, 'int32':3, 'int64':4}
      dTypeSizeDict = {1:4, 2:8, 3:4, 4:8}
      outArray = None
      tshape = []
      sliceNum = 0
      lastSlice = 0
      fullSize = 0
      rowSize = 0
      outSize = 0
      startSlice = 0
      startPos = 0
      endSlice = 0
      endPos = 0
      outPos = 0
      # If the first shape component is non-zero, then this is a fixed size Tensor
      # and exact positions are important.  If not fixed sized, then we take the
      # records sequentially and don't fill gaps.  We determine size by the actual
      # records received.
      isFixedSize = False
      wi = 0
      for rec in tens:
        node, wi, sliceId, shape, dataType, maxSliceSize, slice_size, densedat, sparsedat = rec
        dtype = dTypeDict[dataType]
        tshape = shape
        if outArray is None:
          # Initialize important information on the first slice.
          # Full size of the tensor
          fullSize = np.prod(shape)
          # Is fixed size if the first component of the shape is 0.
          isFixedSize = fullSize != 0
          # Row size is the size of the 2nd - last shape component.
          rowSize = np.prod(shape[1:])
          # Calculate the size to be returned
          outSize = rowSize * datcount
          # Create an array of zeros to hold the output.
          outArray = np.zeros((outSize,), dtype)
          # Figure out which slice and position the desired data starts
          # and ends on
          startSlice, startPos = divmod(pos * rowSize, maxSliceSize)
          endSlice, endPos = divmod((pos + datcount) * rowSize, maxSliceSize)
        if sliceNum < startSlice:
          # The data is found in a later slice.  Skip this one.
          sliceNum += 1
          continue
        if not densedat:
          # Sparse decoding
          dat = np.zeros((slice_size,), dtype)
          for offset, val in sparsedat:
            assert offset < slice_size, 'TensExtract: sparsedat has higher index the sliceSize = ' + str(offset)
            dat[offset] = dtype(val)
          densedat = dat
        if sliceNum == startSlice and sliceNum == endSlice:
          # Data starts and ends on this slice.
          densedat = densedat[startPos:endPos]
        elif sliceNum == startSlice:
          # Data starts on this slice, but ends on a further one.
          densedat = densedat[startPos:]
        elif sliceNum == endSlice:
          # Data ends on this slice but started previously.
          densedat = densedat[:endPos]
        # Add any data from this slice
        outArray[outPos:outPos + len(densedat)] = densedat
        outPos += len(densedat)
        sliceNum += 1
        # If this is the end slice, we're done.
        if sliceNum >= endSlice:
          break
      if sliceNum == 0:
        # No data in the slice.   Return an empty Tensor.
        return []
      if outPos < datcount * rowSize:
        # Fewer than requested records available.
        outArray.resize((outPos,))
      if tshape[0] == 0:
        tshape[0] = -1
      # If this is a variable size tensor, reflect that in the numpy array.
      outArray = np.reshape(outArray, tshape)
      # Function to convert a numpy array to a tensor.
      def Np2Tens(a, wi=1):
        epsilon = .000000001
        origShape = list(a.shape)
        flatA = a.reshape(-1)
        flatSize = flatA.shape[0]
        sliceId = 1
        indx = 0
        maxSliceSize = 0
        datType = dTypeDictR[str(a.dtype)]
        elemSize = dTypeSizeDict[datType]
        max_slice = divmod(maxSliceLen, elemSize)[0]
        while indx < flatSize:
          remaining = flatSize - indx
          if remaining >= max_slice:
            sliceSize = max_slice
          else:
            sliceSize = remaining
          if sliceId == 1:
            maxSliceSize = sliceSize
          dat = list(flatA[indx:indx + sliceSize])
          dat = [float(d) for d in dat]
          elemCount = 0
          for i in range(len(dat)):
            if abs(dat[i]) > epsilon:
              elemCount += 1
          if elemCount > 0 or sliceId == 1:
            if elemCount * (elemSize + 4) < len(dat):
              # Sparse encoding
              sparse = []
              for i in range(len(dat)):
                if abs(dat[i]) > epsilon:
                  sparse.append((i, dat[i]))
              yield (nodeid, wi, sliceId, origShape, datType, maxSliceSize, sliceSize, [], sparse)
            else:
              # Dense encoding
              yield (nodeid, wi, sliceId, origShape, datType, maxSliceSize, sliceSize, dat, [])
          sliceId += 1
          indx += sliceSize

      return Np2Tens(outArray, wi)
    except:
      # Error during extraction.
      assert 0 == 1, 'TensExtract: ' + tb.format_exc()
  ENDEMBED;
  RETURN extract(tens, pos-1, datcount, nodeId, MAX_SLICE);
END;