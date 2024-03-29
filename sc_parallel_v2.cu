#include <stdio.h>
#include <stdint.h>


#define CHECK(call)\
{\
	const cudaError_t error = call;\
	if (error != cudaSuccess)\
	{\
		fprintf(stderr, "Error: %s:%d, ", __FILE__, __LINE__);\
		fprintf(stderr, "code: %d, reason: %s\n", error,\
				cudaGetErrorString(error));\
		exit(EXIT_FAILURE);\
	}\
}

struct GpuTimer
{
	cudaEvent_t start;
	cudaEvent_t stop;

	GpuTimer()
	{
		cudaEventCreate(&start);
		cudaEventCreate(&stop);
	}

	~GpuTimer()
	{
		cudaEventDestroy(start);
		cudaEventDestroy(stop);
	}

	void Start()
	{
		cudaEventRecord(start, 0);                                                                 
		cudaEventSynchronize(start);
	}

	void Stop()
	{
		cudaEventRecord(stop, 0);
	}

	float Elapsed()
	{
		float elapsed;
		cudaEventSynchronize(stop);
		cudaEventElapsedTime(&elapsed, start, stop);
		return elapsed;
	}
};

void readPnm(char * fileName, 
		int &numChannels, int &width, int &height, uint8_t * &pixels)
{
	FILE * f = fopen(fileName, "r");
	if (f == NULL)
	{
		printf("Cannot read %s\n", fileName);
		exit(EXIT_FAILURE);
	}

	char type[3];
	fscanf(f, "%s", type);
	if (strcmp(type, "P2") == 0)
		numChannels = 1;
	else if (strcmp(type, "P3") == 0)
		numChannels = 3;
	else // In this exercise, we don't touch other types
	{
		fclose(f);
		printf("Cannot read %s\n", fileName); 
		exit(EXIT_FAILURE); 
	}

	fscanf(f, "%i", &width);
	fscanf(f, "%i", &height);

	int max_val;
	fscanf(f, "%i", &max_val);
	if (max_val > 255) // In this exercise, we assume 1 byte per value
	{
		fclose(f);
		printf("Cannot read %s\n", fileName); 
		exit(EXIT_FAILURE); 
	}

	pixels = (uint8_t *)malloc(width * height * numChannels);
	for (int i = 0; i < width * height * numChannels; i++)
		fscanf(f, "%hhu", &pixels[i]);

	fclose(f);
}

void writePnm(uint8_t * pixels, int numChannels, int width, int height, 
		char * fileName)
{
	FILE * f = fopen(fileName, "w");
	if (f == NULL)
	{
		printf("Cannot write %s\n", fileName);
		exit(EXIT_FAILURE);
	}	

	if (numChannels == 1)
		fprintf(f, "P2\n");
	else if (numChannels == 3)
		fprintf(f, "P3\n");
	else
	{
		fclose(f);
		printf("Cannot write %s\n", fileName);
		exit(EXIT_FAILURE);
	}

	fprintf(f, "%i\n%i\n255\n", width, height); 

	for (int i = 0; i < width * height * numChannels; i++)
		fprintf(f, "%hhu\n", pixels[i]);

	fclose(f);
}


__global__ void convertRgb2GrayKernel(uint8_t * inPixels, int width, int height, 
		uint8_t * outPixels)
{
	// TODO
    // Reminder: gray = 0.299*red + 0.587*green + 0.114*blue
	int r = blockIdx.y*blockDim.y + threadIdx.y;
	int c = blockIdx.x*blockDim.x + threadIdx.x;
	if(r<height && c<width)
	{
		int i = r * width + c;
		uint8_t red = inPixels[3 * i];
		uint8_t green = inPixels[3 * i + 1];
		uint8_t blue = inPixels[3 * i + 2];
		outPixels[i] = 0.299f*red + 0.587f*green + 0.114f*blue;
	}
}


void convertRgb2Gray(uint8_t * inPixels, int width, int height,
		uint8_t * outPixels, dim3 blockSize=dim3(1))
{
    // TODO: Allocate device memories
    uint8_t *d_inPixels; 
    CHECK(cudaMalloc(&d_inPixels,height*width*3*sizeof(uint8_t)));

    uint8_t *d_outPixels;
    CHECK(cudaMalloc(&d_outPixels,height*width*sizeof(uint8_t)));

    // TODO: Copy data to device memories
    CHECK(cudaMemcpy(d_inPixels,inPixels,height*width*3*sizeof(uint8_t),cudaMemcpyHostToDevice));

    // TODO: Set grid size and call kernel (remember to check kernel error)
    dim3 gridSize(((width-1)/blockSize.x + 1), ((height-1)/blockSize.y + 1));;

    convertRgb2GrayKernel<<<gridSize,blockSize>>>(d_inPixels,width,height,d_outPixels);

    // TODO: Copy result from device memories
    CHECK(cudaMemcpy(outPixels,d_outPixels,height*width*sizeof(uint8_t),cudaMemcpyDeviceToHost));

    // TODO: Free device memories
	cudaFree(d_inPixels);
	cudaFree(d_outPixels);
}


char * concatStr(const char * s1, const char * s2)
{
	char * result = (char *)malloc(strlen(s1) + strlen(s2) + 1);
	strcpy(result, s1);
	strcat(result, s2);
	return result;
}


void writeMatrix(float * matrix, int width, int height, char * fileName)
{
	FILE * f = fopen(fileName, "w");
	if (f == NULL)
	{
		printf("Cannot write %s\n", fileName);
		exit(EXIT_FAILURE);
	}
	for (int r = 0; r < height; r++)
	{
		for (int c = 0; c < width; c++)
		{
			int i = r*width + c;
			fprintf(f, "%f ", matrix[i]);
		}
		fprintf(f, "\n");
	}
	fclose(f);

}

void convolution(uint8_t * inPixels, int width, int height, float * filter, int filterWidth, float * outPixels)
{
    for (int outPixelsR = 0; outPixelsR < height; outPixelsR++)
		{
			for (int outPixelsC = 0; outPixelsC < width; outPixelsC++)
			{
				float outPixel = 0;
				for (int filterR = 0; filterR < filterWidth; filterR++)
				{
					for (int filterC = 0; filterC < filterWidth; filterC++)
					{
						float filterVal = filter[filterR*filterWidth + filterC];
						int inPixelsR = outPixelsR - filterWidth/2 + filterR;
						int inPixelsC = outPixelsC - filterWidth/2 + filterC;
						inPixelsR = min(max(0, inPixelsR), height - 1);
						inPixelsC = min(max(0, inPixelsC), width - 1);
						int inPixel = inPixels[inPixelsR*width + inPixelsC];
						outPixel += (float)filterVal * (float)inPixel;
					}
				}
				outPixels[outPixelsR*width + outPixelsC] = outPixel;
			}
		}
}

__global__ void convolutionKernel(uint8_t * inPixels, int width, int height, float * sobelX, float * sobelY, int filterWidth, float * outPixels)
{
	// TODO
	extern __shared__ uint8_t s_inPixels[];

	int s_blockWidth = blockDim.x + filterWidth - 1;  
	int s_blockHeight = blockDim.y + filterWidth - 1;
	for(int s_inPixelsR = threadIdx.y; s_inPixelsR < s_blockHeight; s_inPixelsR += blockDim.y)
	{
		for(int s_inPixelsC = threadIdx.x; s_inPixelsC < s_blockWidth; s_inPixelsC += blockDim.x)
		{
			int inPixelsR = blockIdx.y * blockDim.y + s_inPixelsR - filterWidth/2;	
			int inPixelsC = blockIdx.x * blockDim.x + s_inPixelsC - filterWidth/2;
			inPixelsR = min(max(0, inPixelsR), height - 1);
			inPixelsC = min(max(0, inPixelsC), width - 1);

			s_inPixels[s_inPixelsR * s_blockWidth + s_inPixelsC] = inPixels[inPixelsR * width + inPixelsC];
		}
	}
	__syncthreads();

	//--------------------------------------------------
	int ix = blockIdx.x * blockDim.x + threadIdx.x;
	int iy = blockIdx.y * blockDim.y + threadIdx.y;

	if (iy < height && ix < width)
	{
		//int i = iy * width + ix;

		float outPixel_X;
		float outPixel_Y;
		for (int filterR = 0; filterR < filterWidth; filterR++)
		{
			for (int filterC = 0; filterC < filterWidth; filterC++)
			{
				// sobelX
				float x_value = sobelX[filterR * filterWidth + filterC];

				int s_inPixelsR = threadIdx.y + filterR;
				int s_inPixelsC = threadIdx.x + filterC;

				float s_inPixel = s_inPixels[s_inPixelsR * s_blockWidth + s_inPixelsC];

				outPixel_X += x_value * s_inPixel;

				// sobelY
				float y_value = sobelY[filterR * filterWidth + filterC];
				outPixel_Y += y_value * s_inPixel;
			}
		}
		outPixels[iy * width + ix] = abs(outPixel_X) + abs(outPixel_Y);
	}
}

void calcEnergy(uint8_t * inPixels, int width, int height, float * outPixels, dim3 blockSize = dim3(1,1))
{
	int filterWidth = 3;
	float sobelX[9] = {1,0,-1,2,0,-2,1,0,-1};
	float sobelY[9] = {1,2,1,0,0,0,-1,-2,-1};
		
	// Allocate device memories
	int pixelsSize = width * height;
	int filterSize = filterWidth * filterWidth * sizeof(float);

	uint8_t * d_inPixels;
	float * d_filter_X, * d_filter_Y, * d_outPixels;

	CHECK(cudaMalloc(&d_inPixels, pixelsSize * sizeof(uint8_t)));
	CHECK(cudaMalloc(&d_filter_X, filterSize));
	CHECK(cudaMalloc(&d_filter_Y, filterSize));
	CHECK(cudaMalloc(&d_outPixels, pixelsSize * sizeof(float)));

	// Copy data to device memories
	CHECK(cudaMemcpy(d_inPixels, inPixels, pixelsSize * sizeof(uint8_t), cudaMemcpyHostToDevice));
	CHECK(cudaMemcpy(d_filter_X, sobelX, filterSize, cudaMemcpyHostToDevice));
	CHECK(cudaMemcpy(d_filter_Y, sobelY, filterSize, cudaMemcpyHostToDevice));

	// Call kernel
	dim3 gridSize((width-1)/blockSize.x + 1, (height-1)/blockSize.y + 1);
	printf("block size %ix%i, grid size %ix%i\n", blockSize.x, blockSize.y, gridSize.x, gridSize.y);

	int s_Size = ((blockSize.x + filterWidth - 1) * (blockSize.y + filterWidth - 1)) * sizeof(uint8_t);
	convolutionKernel<<<gridSize, blockSize, s_Size>>>(d_inPixels, width, height, d_filter_X, d_filter_Y, filterWidth, d_outPixels);

	// convolution(inPixels, width, height, sobelX, filterWidth, _X);
	
	// convolution(inPixels, width, height, sobelY, filterWidth, _Y);
	cudaDeviceSynchronize();
	CHECK(cudaGetLastError());

	// Copy result from device memory
	CHECK(cudaMemcpy(outPixels, d_outPixels, pixelsSize*sizeof(float), cudaMemcpyDeviceToHost));

	// Free device memories
	CHECK(cudaFree(d_inPixels));
	CHECK(cudaFree(d_filter_X));
	CHECK(cudaFree(d_filter_Y));
	CHECK(cudaFree(d_outPixels));
}

void calcCumulativeEnergyMatrix(float* energyMatrix, int width, int height, float* sumEnergyMatrix)
{
	float* lastRowEnergy = &energyMatrix[height * width -1];
	float* lastRowTable = &sumEnergyMatrix[height * width - 1];

	for (int i = width ; i > 0; i--)
	{
		*(sumEnergyMatrix + height * width - i ) = *(lastRowEnergy - i + 1);
	}
	// Duyet mang energy
	for (int row = height - 2; row  >=  0; row--, lastRowEnergy -= width , lastRowTable -= width)
	{
		// Xet vi tri dau cua mot dong
		lastRowTable[-width ] = lastRowEnergy[-width] + min(lastRowTable[0] , lastRowTable[-1] );
		// Xet cac vi khac
		for (int col = 2; col < width ; col++)
		{
			*(lastRowTable -col - width + 1) = *(lastRowEnergy - col - width + 1) + min(min(lastRowTable[-col + 1] , lastRowTable[-col] ), lastRowTable[-col + 2] );
		}
		// Xet vi tri cuoi
		lastRowTable[-width - width + 1] = lastRowEnergy[-width - width + 1] + min(lastRowTable[-width + 1] , lastRowTable[-width + 2] );
	}
}

__global__ void calcCumulativeEnergyMatrixKernel(float* energyMatrix,
	 int width,	 int height, float* sumEnergyMatrix)
{
	float* lastRowEnergy = &energyMatrix[height * width -1];
	float* lastRowTable = &sumEnergyMatrix[height * width - 1];

	//thread's global id
	int i = threadIdx.x + blockIdx.x * blockDim.x;

	if(i >= width)
		return;

	*(lastRowTable - i) = *(lastRowEnergy - i);
	__syncthreads();

	for (int row = height - 2; row  >=  0;
		row--, lastRowEnergy -= width , lastRowTable -= width)
	 {
		 // Xet vi tri dau cua mot dong
		 if(i == 0)
			 lastRowTable[-width] = lastRowEnergy[-width] + min(lastRowTable[0] , lastRowTable[-1] );
			 else if(i == width-1) // Xet vi tri cuoi
			 lastRowTable[-width - width + 1] = lastRowEnergy[-width - width + 1] + min(lastRowTable[-width + 1] , lastRowTable[-width + 2] );
			 else // Xet cac vi tri khac
		 *(lastRowTable -i - width) = *(lastRowEnergy -i - width) + min(min(lastRowTable[-i + 1] , lastRowTable[-i] ), lastRowTable[-i -1] );
		 __syncthreads();
	 }
}

void meaningLess_Seam(float * sumEnergyMatrix, int width, int height, float * chosenSeam)
{
	int tmp;
	float* pTable = sumEnergyMatrix;
	// Tim phan tu nho nhat trong dong thu 0
	int minVal = pTable[0];
	int minPos = 0;
	
	for (int i = 0; i < width; i++)
	{
		if (pTable[i] < minVal)
		{
			minVal = pTable[i];
			minPos = i;
		}
	}
	chosenSeam[0] = minPos;
	pTable += width;
	// Duyet qua các dong
	for (int row = 1; row < height; row++, pTable +=width)
	{
		if (minPos == 0) //  o dau
		{
			minPos = pTable[0] < pTable[1] ? 0 : 1;
			
		}
		else if(minPos == width - 1) // o cuoi
		{
			minPos = pTable[width - 1] < pTable[width - 2] ? width - 1 : width - 2;
		}
		else // o giua
		{
			tmp = pTable[minPos] < pTable[minPos + 1] ? minPos : minPos + 1;
			if (pTable[tmp] > pTable[minPos - 1])
				minPos = minPos - 1;
			else
				minPos = tmp;
		}
		chosenSeam[row] = minPos;
	}
}

void deleteChosenSeam(uint8_t * inPixels, float* table, float* energyMatrix, float* chosenSeam, int height, int cur_width)
{
	// convert position in row --> position in all matrix
	for(int i=0;i<height;i++)
	{
		chosenSeam[i] += i*cur_width;

		for(int j=chosenSeam[i]-i; j<cur_width*height-i-1;j++)
		{
			table[j] = table[j+1];
			energyMatrix[j] = energyMatrix[j+1];

			//delete in P3 color
			inPixels[j*3] = inPixels[(j+1)*3];
			inPixels[j*3+1] = inPixels[(j+1)*3 + 1];
			inPixels[j*3+2] = inPixels[(j+1)*3 + 2];
		}
	}
}

int main(int argc, char ** argv)
{	
	for(int i=0;i<argc;i++)
	{
		printf("%d: %s\n ",i, argv[i]);
	}

	// Read input RGB image file
	int numChannels, width, height;
	uint8_t * inPixels;
	readPnm(argv[1], numChannels, width, height, inPixels);
	if (numChannels != 3)
		return EXIT_FAILURE; // Input image must be RGB
	printf("Image size (width x height): %i x %i\n\n", width, height);

	// Convert RGB to grayscale using device
	uint8_t * grayOutPixels = (uint8_t *)malloc(width * height*sizeof(uint8_t));
	dim3 blockSize(32, 32); // Default

	convertRgb2Gray(inPixels, width, height, grayOutPixels, blockSize); 
	cudaError_t errSync = cudaGetLastError();
	cudaError_t errAsync = cudaDeviceSynchronize();
	if(errSync!=cudaSuccess)
	{
		printf("Sync kernel error: %s\n", cudaGetErrorString(errSync));
		// Free memories
		free(inPixels);
		free(grayOutPixels);
		return 0;
	}
	if(errAsync!=cudaSuccess)
	{
		printf("Async kernel error: %s\n", cudaGetErrorString(errAsync));
		// Free memories
		free(inPixels);
		free(grayOutPixels);
		return 0;
	}

	// Write results to files
	char * outFileNameBase = strtok(argv[2], "."); // Get rid of extension
	writePnm(grayOutPixels, 1, width, height, concatStr(outFileNameBase, ".pnm"));


    float* energyMatrix = (float*)malloc(width*height*sizeof(float));
    calcEnergy(grayOutPixels, width, height, energyMatrix, blockSize);
    
    writeMatrix(energyMatrix, width, height, argv[3]);
    
	float* sumEnergyMatrix = (float*)malloc(width*height*sizeof(float));
	float* chosenSeam = (float*)malloc(height*sizeof(float));

    int width_expect = atoi(argv[6]);
    int cur_width = width;
    while(width_expect < cur_width)
    {
	// 		//Serial implementation
	// 		calcCumulativeEnergyMatrix(energyMatrix, cur_width, height, sumEnergyMatrix);
			
		//Parallel implementation
		float* d_energyMatrix;
		float* d_sumEnergyMatrix;
		CHECK(cudaMalloc(&d_energyMatrix, width*height*sizeof(float)));
		CHECK(cudaMalloc(&d_sumEnergyMatrix, width*height*sizeof(float)));
		CHECK(cudaMemcpy(d_energyMatrix, energyMatrix, width*height*sizeof(float), cudaMemcpyHostToDevice));
		
		//remember to edit
		calcCumulativeEnergyMatrixKernel<<<1, 1024>>>(d_energyMatrix, cur_width, height, d_sumEnergyMatrix);
		
		cudaDeviceSynchronize();
		CHECK(cudaGetLastError());

		CHECK(cudaMemcpy(sumEnergyMatrix, d_sumEnergyMatrix, width*height*sizeof(float), cudaMemcpyDeviceToHost));
			
		// find the seam will be remove
		meaningLess_Seam(sumEnergyMatrix, cur_width, height, chosenSeam);
		
		// remove this seam (in eneryMatrix, sumEnergyMatrix and pnm image)
		deleteChosenSeam(inPixels, sumEnergyMatrix, energyMatrix, chosenSeam, height, cur_width);
		cur_width--;
			
		cudaFree(d_energyMatrix);
		cudaFree(d_sumEnergyMatrix);
	}
	
	writeMatrix(energyMatrix, cur_width, height, argv[4]);
	writePnm(inPixels,3,cur_width,height,argv[5]);
    printf("Image size after Seam Carving (width x height): %i x %i\n\n", cur_width, height);

    // Free memories
    free(inPixels);
    
	free(energyMatrix);
	free(sumEnergyMatrix);
	free(chosenSeam);
}