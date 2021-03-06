% Params(3) = 6;
% Params(4) = 50000;
% Params(5) = 25; 

Params(3) = ops.Thfinal;
Params(4) = 50000;
Params(5) = 50; 

% ParamsW = Params;
% ParamsW(2)= Nrank*Nfilt;
% utu = gpuArray.ones(Nrank*Nfilt, 'single');
% wtw = mexWtW(ParamsW, W(:,:), utu);
% wtw = reshape(wtw, Nfilt, Nrank, Nfilt, Nrank, 2*nt0-1);

U0 = gpuArray(U);
WtW  = gpuArray.zeros(Nfilt,Nfilt, 2*nt0-1, 'single');
for i = 1:Nrank
    for j = 1:Nrank
        utu0 = U0(:,:,i)' * U0(:,:,j);
        wtw0 = mexWtW2(Params, W(:,:,i), W(:,:,j), utu0);
%         wtw0 = squeeze(wtw(:,i,:,j,:));
        WtW = WtW + wtw0;
    end
end
%

mWtW = max(WtW, [], 3);
murep = repmat(mu, 1, Nfilt);
mWtW = mWtW .* (min(murep , murep')./max(murep , murep'));
mWtW = gather(mWtW);

mWtW = mWtW - diag(diag(mWtW));

WtW = permute(WtW, [3 1 2]);
% rez.WtW = gather(WtW);
%
clear wtw0 utu0 U0
%
clear nspikes2
st3 = [];
st3pos = [];
rez.st3 = [];
rez.st3pos = [];

if ops.verbose
   fprintf('Time %3.0fs. Running the final template matching pass...\n', toc) 
end

fid = fopen(fullfile(root, fnameTW), 'r');
msg = [];
%
for ibatch = 1:Nbatch
    if ibatch>1 && ismember(rem(ibatch,Nbatch), iUpdate) %&& i>Nbatch
        dWUtotCPU = gather(dWUtot);
        ntot = sum(nspikes,2);

        for k = 1:maxNfilt(i)
            if ntot(k)>5
                [Uall, Sv, Vall] = svd(gather(dWUtotCPU(:,:,k)), 0);
                
                Sv = diag(Sv);
                sumSv2 = sum(Sv(1:Nrank).^2).^.5;
                for irank = 1:Nrank
                    [~, imax] = max(abs(Uall(:,irank)), [], 1);
                    W(:,k,irank) = - Uall(:,irank) * sign(Uall(imax,irank)) * Sv(irank)/sumSv2;
                    U(:,k,irank) = - Vall(:,irank) * sign(Uall(imax,irank));
                end
                mmax = max(abs(U(:,k,1)));
                Usize = squeeze(abs(U(:,k,:)));
                Usize = Usize .* repmat(Sv(1:Nrank)'/Sv(1), Nchan, 1);
                ibad = max(Usize, [], 2) < .1 * mmax;
                
                U(ibad,k,:) = 0;
            end
        end
        
        for k = 1:maxNfilt(i)
            if ntot(k)>5                
                wu = squeeze(W(:,k,:)) * squeeze(U(:,k,:))';
                mu(k) = sum(sum(wu.*squeeze(dWUtotCPU(:,:,k))))/npm(k);
            end
        end
        if i<Nbatch * ops.nfullpasses
            W = alignW(W);
        end
        for k = 1:maxNfilt(i)
            if ntot(k)>5
                wu = squeeze(W(:,k,:)) * squeeze(U(:,k,:))';
                newnorm = sum(wu(:).^2).^.5;
                W(:,k,:) = W(:,k,:)/newnorm;
            end
        end
        
        if i>Nbatch * ops.nfullpasses
            break;
        end
                
        rez.errall(ceil(i/freqUpdate))          = nanmean(delta);

        plot(sort(mu))
        axis tight
        drawnow
    end
    
    if ibatch>Nbatch_buff
        offset = 2 * ops.Nchan*batchstart(ibatch-Nbatch_buff); % - ioffset;
        fseek(fid, offset, 'bof');
        dat = fread(fid, [NT ops.Nchan], '*int16');
    else
       dat = DATA(:,:,ibatch); 
    end
    dataRAW = gpuArray(dat);
    dataRAW = single(dataRAW);
    dataRAW = dataRAW / ops.scaleproc;
    
    % nonlinearity on raw data
%     dataRAW = 8*(2./(1+exp(-dataRAW/4)) - 1);
    
    data 	= dataRAW * U(:,:); 
    
    [st, id, x] = mexMPmuLITE(Params,data,W,WtW, mu, lam); % * 20./mu);
    %     [drez, dW, dU, st, id, x] = mexMPsub(Params,dataRAW,W,U,data,WtW);
    if ibatch==1
        ioffset = 0;
    else
        ioffset = ops.ntbuff;
    end
    st = st - ioffset;
    
    nspikes2(1:size(W,2)+1, ibatch) = histc(id, 0:1:size(W,2));
%     delta(ibatch) = sum(x.^2)/1e6;
    STT = cat(2, double(st) +(NT-ops.ntbuff)*(ibatch-1), double(id)+1, double(x), ibatch*ones(numel(x),1));
    st3 = cat(1, st3, STT);
    
%     max(st(:))
    
    if rem(ibatch,100)==1
        nsort = sort(sum(nspikes2,2), 'descend');
        fprintf(repmat('\b', 1, numel(msg)));
        msg = sprintf('Time %2.2f, batch %d/%d, err %2.6f, NTOT %d, n100 %d, n200 %d, n300 %d, n400 %d\n', ...
            toc, ibatch,Nbatch, nanmean(delta), sum(nspikes2(:)), nsort(min(size(W,2), 100)),nsort(min(size(W,2), 200)), ...
            nsort(min(size(W,2), 300)), nsort(min(size(W,2), 400)));
        fprintf(msg);
    end
end
%
nsort = sort(sum(nspikes2,2), 'descend');
fprintf('Time %3.0fs. ExpVar %2.6f, n10 %d, n20 %d, n30 %d, n40 %d \n', toc, nanmean(delta), nsort(10), nsort(20), ...
    nsort(min(size(W,2), 30)), nsort(min(size(W,2), 40)));

%%
fprintf('Time %3.0fs. Thresholding spikes at false positive rate...\n', toc) 
st3pos = [];
fprate = ops.fprate;
Thx = zeros(Nfilt,1);
for idd = 1:1:Nfilt
    ix = find(st3(:,2)==idd);
    xs = st3(ix, 3);
    
    Mu = 10*ops.Th;
    Nbins = 1000;
    
    bbins = linspace(0, Mu, Nbins);
    hpos = cumsum(hist(Mu - xs(xs>0), bbins));
    hneg = cumsum(hist(Mu + xs(xs<0), bbins));
    
    ifirst = find(hneg./hpos > fprate, 1);
    if isempty(ifirst)
        ifirst = numel(bbins);
    end
    Thx(idd) = Mu - bbins(ifirst);
    
    st3pos = cat(1, st3pos, st3(ix(xs>Thx(idd)), :));
end

[~, isort] = sort(st3pos(:,1), 'ascend');
st3pos = st3pos(isort,:);

rez.st3      = st3; 
rez.st3pos   = st3pos; 
rez.ops      = ops;

% WUnorms = sum(sum(dWUtotCPU.^2, 2), 1).^.5;
% rez.template = gather(dWUtotCPU ./ repmat(WUnorms, nt0, Nchan, 1));

rez.W = W;
rez.U = U;
rez.t2p = [];
for i = 1:Nfilt
    wav0 = W(:,i,1);
    wav0 = my_conv(wav0', .5)';
   [~, itrough] = min(wav0);
    [~, t2p] = max(wav0(itrough:end));
    rez.t2p(i,1) = t2p;
    rez.t2p(i,2) = itrough;   
end

rez.nbins = histc(rez.st3pos(:,2), .5:1:Nfilt+1);

[~, rez.ypos] = max(rez.U(:,:,1), [], 1);

fclose(fid);
%
% gather_raw_mean_spikes;
% rez.Wraw = Wraw;


%%
% testCode;
% estimateErrors;

