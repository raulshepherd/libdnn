#include <dnn.h>
#include <dnn-utility.h>

DNN::DNN() {}

DNN::DNN(string fn): _dims(0) {
  this->read(fn);
}

DNN::DNN(const std::vector<size_t>& dims): _dims(dims) {
  size_t L = _dims.size() - 1;
  _weights.resize(L);

  for (size_t i=0; i<L; ++i) {
    size_t M = _dims[i] + 1;
    size_t N = _dims[i+1];

    // If not output layer, reserve last column for bias 
    if (i < L - 1)
      N += 1;

    _weights[i].resize(M, N);
  }

  for (size_t i=0; i<L; ++i)
    ext::randn(_weights[i]);
}

DNN::DNN(const DNN& source): _dims(source._dims), _weights(source._weights) {
}

DNN& DNN::operator = (DNN rhs) {
  swap(*this, rhs);
  return *this;
}

size_t DNN::getNLayer() const {
  return _dims.size(); 
}

size_t DNN::getDepth() const {
  return _dims.size() - 2;
}

#pragma GCC diagnostic ignored "-Wunused-result"
void readweight(FILE* fid, float* w, size_t rows, size_t cols) {

  for (size_t i=0; i<rows - 1; ++i)
    for (size_t j=0; j<cols; ++j)
      fscanf(fid, "%f ", &(w[j * rows + i]));

  fscanf(fid, "]\n<sigmoid>\n [");

  for (size_t j=0; j<cols; ++j)
    fscanf(fid, "%f ", &(w[j * rows + rows - 1]));
  fscanf(fid, "]\n");

}

#pragma GCC diagnostic ignored "-Wunused-result"
void DNN::read(string fn) {
  FILE* fid = fopen(fn.c_str(), "r");

  _dims.clear();
  _weights.clear();

  size_t rows, cols;

  while (fscanf(fid, "<affinetransform> %lu %lu\n [\n", &rows, &cols) != EOF) {

    printf("rows = %lu, cols = %lu \n", rows, cols);

    float* hw = new float[(rows + 1) * cols];
    readweight(fid, hw, rows + 1, cols);

    // Reserve one more column for bias)
    mat w(rows + 1, cols + 1);
    CCE(cudaMemcpy(w.getData(), hw, sizeof(float) * (rows + 1) * cols, cudaMemcpyHostToDevice));
    _weights.push_back(w);
    delete [] hw;

    _dims.push_back(rows);
  }
  _dims.push_back(cols);

  // No need for one more column in the last weight matrix, resize it back.
  // (since I cannot tell which "i" is the last one in the while loop. )
  _weights.back().resize(rows + 1, cols);
  
  fclose(fid);
}

void DNN::save(string fn) const {
  FILE* fid = fopen(fn.c_str(), "w");

  for (size_t i=0; i<_weights.size(); ++i) {
    const mat& w = _weights[i];

    size_t rows = w.getRows();
    size_t cols = w.getCols();

    if (i != _weights.size() - 1)
      cols -= 1;

    fprintf(fid, "<affinetransform> %lu %lu \n", rows - 1, cols);
    fprintf(fid, " [");

    // ==============================
    float* data = new float[w.size()];
    CCE(cudaMemcpy(data, w.getData(), sizeof(float) * w.size(), cudaMemcpyDeviceToHost));

    for (size_t j=0; j<rows-1; ++j) {
      fprintf(fid, "\n  ");
      for (size_t k=0; k<cols; ++k)
	fprintf(fid, "%g ", data[k * rows + j]);
    }
    fprintf(fid, "]\n");

    fprintf(fid, "<sigmoid> \n [");
    for (size_t j=0; j<cols; ++j)
      fprintf(fid, "%g ", data[j * rows + rows - 1]);
    fprintf(fid, " ]\n");

    delete [] data;
  }

  fprintf(stdout, "nn_structure ");
  for (size_t i=0; i<_dims.size(); ++i)
    fprintf(stdout, "%lu ", _dims[i]);
  fprintf(stdout, "\n");
  
  fclose(fid);
}

void DNN::print() const {
  for (size_t i=0; i<_weights.size(); ++i)
    _weights[i].print(stdout);
}

void DNN::getEmptyGradient(std::vector<mat>& g) const {
  g.resize(_weights.size());
  for (size_t i=0; i<_weights.size(); ++i) {
    int m = _weights[i].getRows();
    int n = _weights[i].getCols();
    g[i].resize(m, n);
  }
}

std::vector<mat>& DNN::getWeights() { return _weights; }
const std::vector<mat>& DNN::getWeights() const { return _weights; }
std::vector<size_t>& DNN::getDims() { return _dims; }
const std::vector<size_t>& DNN::getDims() const { return _dims; }

// ========================
// ===== Feed Forward =====
// ========================

void print(const thrust::host_vector<float>& hv) {
  cout << "\33[33m[";
  for (size_t i=0; i<hv.size(); ++i)
    cout << hv[i] << " ";
  cout << " ] \33[0m" << endl << endl;
}

void print(const mat& m) {
  thrust::device_ptr<float> dm(m.getData());
  thrust::host_vector<float> hm(dm, dm + m.size());

  ::print(hm);
}

void print(const thrust::device_vector<float>& dv) {
  thrust::host_vector<float> hv(dv.begin(), dv.end());
  ::print(hv);
}

void DNN::train(const DataSet& train, const DataSet& valid, size_t batchSize, ERROR_MEASURE err) {
  
  /*printf("Training...\n");
  perf::Timer timer;
  timer.start();*/

  vector<mat> O(this->getNLayer());
  std::vector<mat> gradient;
  this->getEmptyGradient(gradient);

  size_t input_dim = train.X.getCols(),
	 output_dim= train.y.getCols();

  size_t Ein, Eout;
  size_t prevEout = valid.y.size();
  size_t MAX_EPOCH = 1024, epoch;

  size_t nTrain = train.X.getRows(),
	 nValid = valid.X.getRows();

  size_t nBatch = nTrain / batchSize,
         remained = nTrain - nBatch * batchSize;

  if (remained > 0)
    ++nBatch;

  for (epoch=0; epoch<MAX_EPOCH; ++epoch) {

    for (size_t b=0; b<nBatch; ++b) {

      size_t offset = b*batchSize;
      size_t nData = batchSize;

      if (b == nBatch - 1)
	nData = min(remained - 1, batchSize);

      this->feedForward(train.X, &O, offset, nData);

      // mat error = O.back() - train.y;
      mat error = calcError(O.back(), train.y, offset, nData);

      this->backPropagate(error, O, gradient);
      this->updateParameters(gradient, 5 * 1e-3);
    }

    this->feedForward(valid.X, &O);

    Eout = zeroOneError(O.back(), valid.y);

    if (Eout > prevEout && (float) Eout / nValid < 0.2)
      break;

    prevEout = Eout;
  }

  // Show Summary
  printf("\n%d epochs in total\n", epoch);
  // timer.elapsed();

  this->feedForward(train.X, &O);
  Ein = zeroOneError(O.back(), train.y);

  printf("[   In-Sample   ] ");
  showAccuracy(Ein, train.y.size());
  printf("[ Out-of-Sample ] ");
  showAccuracy(Eout, valid.y.size());

}

void DNN::feedForward(const mat& x, std::vector<mat>* hidden_output, size_t offset, size_t batchSize) {
  assert(hidden_output != NULL);
  assert(batchSize >= 0 && offset + batchSize <= x.getRows());

  // All data in one-batch (Gradient Descent)
  if (batchSize == 0)
    batchSize = x.getRows();

  std::vector<mat>& O = *hidden_output;
  assert(O.size() == _dims.size());

  O[0].resize(batchSize, x.getCols() + 1);

  memcpy2D(O[0], x, offset, 0, batchSize, x.getCols(), 0, 0);
  fillLastColumnWith(O[0], (float) 1.0);

  size_t end = O.size() - 1;
  for (size_t i=0; i<end - 1; ++i) {
    O[i+1] = ext::sigmoid(O[i] * _weights[i]);
    fillLastColumnWith(O[i+1], (float) 1.0);
  }

  O[end] = ext::sigmoid(O[end - 1] * _weights[end - 1]);
}

// ============================
// ===== Back Propagation =====
// ============================

void DNN::backPropagate(mat& delta, std::vector<mat>& O, std::vector<mat>& gradient) {
  assert(gradient.size() == _weights.size());

  for (int i=_weights.size() - 1; i >= 0; --i) {

    gradient[i] = ~O[i] * delta;
    // delta *= ~_weights[i];
    
    //   delta = delta(:, 1:end-1) * ~_weights[i]
    //
    //                  (temp)
    //     delta'    =  delta    x     (weigth)^T
    // -------------------------------------------
    //       7                             7
    // |<--------->|   ----->|       |<--------->|
    // o o o o o o o = o o o o o x | o o o o o o o 
    // o o o o o o o   o o o o o   | o o o o o o o 
    // o o o o o o o   o o o o o   | o o o o o o o 
    //                             v o o o o o o o 
    //                               o o o o o o o  (<== bias, don't use them when back-propagate)

    size_t D1 = _weights[i].getRows() - 1,
           D2 = (i == _weights.size() - 1) ? delta.getCols() 
					   : delta.getCols() - 1,
           nData = delta.getRows();

    mat tmp(delta);
    delta.resize(nData, D1 + 1);

    device_matrix<float>::cublas_gemm(
	CUBLAS_OP_N, CUBLAS_OP_T,
	nData, D1 + 1, D2 /* Ignore last column, which is the bias */,
	1.0,
	tmp.getData(), nData,
	_weights[i].getData(), D1 + 1,
	0.0,
	delta.getData(), nData);
    
    thrust::device_vector<float> temp(O[i].size());

    thrust::device_ptr<float> output(O[i].getData());
    thrust::transform(output, output + O[i].size(), temp.begin(), func::dsigma<float>());

    thrust::device_ptr<float> dv1(delta.getData());
    thrust::transform(dv1, dv1 + delta.size(), temp.begin(), dv1, thrust::multiplies<float>());
  }
}

void DNN::updateParameters(std::vector<mat>& gradient, float learning_rate) { 
  for (size_t i=0; i<_weights.size(); ++i) {
    gradient[i] *= learning_rate;
    _weights[i] -= /*learning_rate * */gradient[i];
  }
}

void swap(DNN& lhs, DNN& rhs) {
  using WHERE::swap;
  swap(lhs._dims   , rhs._dims   );
  swap(lhs._weights, rhs._weights);
}

// =============================
// ===== Utility Functions =====
// =============================

mat l2error(mat& targets, mat& predicts) {
  mat err(targets - predicts);

  thrust::device_ptr<float> ptr(err.getData());
  thrust::transform(ptr, ptr + err.size(), ptr, func::square<float>());

  mat sum_matrix(err.getCols(), 1);
  err *= sum_matrix;
  
  return err;
}

