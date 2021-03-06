classdef DifferentiableContactDynamics 
    %UNTITLED6 Summary of this class goes here
    %   Detailed explanation goes here
    
    properties
        terrain;
        timestep = 0.01;
        contactSolver = PathLCPSolver();  
        lcpCache = [];
        cacheFlag = false;
        contact_integration_method = 1;
        %NOTE on CONTACT_INTEGRATION_METHOD
        %   Values have the following meaning:
        %       1: Forward integration. Contact is evaluated at the
        %       (projected) next configuration
        %       2: Backward integration. Contact is evaluated at the given
        %       configuration
        %       3: Midpoint integration. Contact is evaluated at the next
        %       (projected) configuration, but the projection is performed
        %       using half the timestep
    end
    
    methods
        
        function obj = DifferentiableContactDynamics(terrainObj)
           if nargin == 1
               obj.terrain = terrainObj;
           else
              obj.terrain = FlatTerrain(); 
           end
        end
    end
    methods (Sealed = true)
        function [t,x] = simulate(obj, Tf, x0, u)
            
            % Pre-initialize arrays
            nX = numel(x0);
            t = 0:obj.timestep:Tf;
            nT = numel(t);
            x = zeros(nX, nT);
            x(:,1) = x0;
            if nargin == 3
                u = zeros(obj.numU, nT);
            end
            % Run the simulation loop
            for n = 1:nT-1
               dx = obj.dynamics(t(n), x(:,n), u(:,n));
               % Simulate using semi-implicit integration
               % First integrate the velocity
               x(obj.numQ+1:end,n+1) = x(obj.numQ+1:end,n) + obj.timestep * dx(obj.numQ+1:end,:);
               % Now integrate the position
               x(1:obj.numQ,n+1) = x(1:obj.numQ,n) + x(obj.numQ+1:end,n+1) * obj.timestep;
            end
        end
        function [H, C, B, dH, dC, dB] = manipulatorDynamics(obj,q,dq)
            %% MANIPULATORDYNAMICS: Returns parameters for calculating the system dynamics
            %
            %   manipulatorDynamics calculates and returns the mass matrix,
            %   force effects, and input selection matrix, and their
            %   derivatives, for use in calculating the system dynamics.
            %   manipulatorDynamics is a required method for subclasses of
            %   Drake's Manipulator class.
            %
            %   Syntax:
            %       [H,C,B,dH,dC,dB] = manipulatorDynamics(obj, q, dq);
            %       [H,C,B,dH,dC,dB] = obj.manipulatorDynamics(q,dq);
            %
            %   Arguments:
            %       OBJ: A DifferentiableContactDynamics object
            %       q:   Nx1 double, the configuration vector
            %       dq:  Nx1 double, the configuration rate vector
            %
            %   Return Values:
            %       H:  NxN double, the mass matrix evaluated at q
            %       dH: NxN^2 double, the derivatives of the mass matrix with
            %           respect to q
            %       C:  Nx1 double, a vector of force effects evaluated at
            %           q
            %       dC: Nx2N double, the derivatives of C wrt q and dq
            %       B:  NxM double, the control selection matrix
            %       dB: NxNM double, the derivatives of B wrt q
            %
            %   Note: for dH, every N columns is a derivative wrt a 
            %   different element in q. i.e. dH(:,1:N) is the derivative 
            %   wrt q(1). Likewise, every M columns of dB is a derivative 
            %   wrt each q.
            
            % Get the system parameters
            [H, dH] = obj.massMatrix(q);
            [C, dC] = obj.coriolisMatrix(q,dq);
            [N, dN] = obj.gravityMatrix(q);
            [B, dB] = obj.controllerMatrix(q);
            % Calculate the gradient of C (coriolis matrix) wrt q
            dC = squeeze(sum(dC .* dq', 2));
            % Gradient of force effects wrt [q, dq]
            dC = dC + [dN, C];
            % Combine the coriolis and gravitational effects
            C = C*dq + N;
            % Reshape dM and dB
            dH = reshape(dH, [size(dH, 1), size(dH,2) * size(dH, 3)])';
            dB = reshape(dB, [size(dB, 1), size(dB, 2) * size(dB, 3)])';
        end
        function [f, df] = dynamics(obj, t, x, u)
            %% DYNAMICS: Evaluates the dynamics of the Lagrangian System
            %
            %   [f, df] = dynamics(plant, t, x, u) returns the dynamics of the
            %   Lagrangian System PLANT as a vector of derivatives of the
            %       xA: the point on the manipulator nearest the terrain
            %   state such satisfying:
            %           f = dx/dt
            %
            %   In general, we write the dynamics as a first-order form as:
            %           dx/dt = f(t,x,u)
            %
            %   Where x is the state vector and u is the control vector
            %
            %   DYNAMICS also returns the gradient of the dynamics, df,
            %   with respect to both the state and the controls:
            %
            %       df = [df/dt; df/dx; df/du]
            %
            %   ARGUMENTS:
            %       PLANT:  a DIFFERENTIABLELAGRANGIAN Model
            %       t:      scalar time variable (unused)
            %       x:      2*nQ x 1 vector of state variables
            %       u:      2*nQ x 1 vector of control variables
            %
            %   RETURN VALUES:
            %       f:      2*nQx1 vector of first derivatives of the state
            %       df:     2*nQ x (2*nQ + nU + 1) vector, the gradient of the
            %               dynamics
            %
            %   The returned dynamics are evaluated semi-implicitly. That
            %   is, they are evaluated at the next time step, assuming
            %   constant velocity.
            
            % Get the configuration and the velocities
            q = x(1:obj.numQ);
            dq = x(obj.numQ+1:end);
            % Solve the contact problem
            [fc, dfc, ~] = obj.contactForce(q, dq, u);
            % Cache the LCP Solution, if necessary
            if obj.cacheFlag
                f_time = obj.lcpCache.data.time;
                [~, id] = min(abs(f_time - t));
                obj.lcpCache.data.time(id) = t;
                obj.lcpCache.data.force(:,id) = fc;
            end
            % Get the physical parameters of the system (mass matrix, etc)
            [M, C, B, dM, dC, dB] = obj.manipulatorDynamics(q, dq);
            [Jn, Jt, dJn, dJt] = obj.contactJacobian(q);
            % Transpose the Jacobians
            Jc = [Jn; Jt]';
            dJc = permute(cat(1,dJn, dJt), [2,1,3]);
            
            % Invert the mass matrix, as we'll use the inverse several
            % times.
            R = chol(M);
            %Minv = M\eye(obj.numQ);
            
            % Calculate the dynamics f
            tau = B*u - C;
            ddq = R\(R'\(tau + Jc * fc));
            
            % Dynamics
            f = [dq; ddq];
            
            if nargout == 2
                dM = reshape(dM', obj.numQ*[1,1,1]);
                dB = reshape(dB', [obj.numQ, obj.numU, obj.numQ]);
                % First calculate the derivatives without the contact force
                % derivative
                % Calculate the gradient wrt q
                dBu = squeeze(sum(dB .* u', 2));
                dJc_f = squeeze(sum(dJc .* fc', 2));               
                % Gradient of tau wrt q
                dtau_q = dBu - dC(:,1:obj.numQ);
                % Gradient of tau wrt dq
                dtau_dq = - dC(:,obj.numQ+1:end);
                % Gradient of the inverse mass matrix
                dMinv = zeros(size(dM));
                for n = 1:obj.numQ
                    dMinv(:,:,n) = -R\(R'\dM(:,:,n)/R)/R';
                end
                % Multiply by tau and contact force
                dMinv_tau_f = squeeze(sum(dMinv .* (tau + Jc*fc)', 2));
                % Calculate the gradients with fixed contact force
                df2_q = dMinv_tau_f + (R\(R'\(dtau_q + dJc_f)));
                df2_dq = R\(R'\dtau_dq);
                df2_u = R\(R'\B);
                % Combine the individual gradients into one
                df2 = [df2_q, df2_dq, df2_u];
                % Now add in the gradients of the contact force
                df2 = df2 + (R\(R'\(Jc * dfc)));
                % Calculate the gradients of the position
                df1 = [zeros(obj.numQ), eye(obj.numQ), zeros(obj.numQ, obj.numU)];     
                % Combine all the gradients into one
                df = [df1; df2];
                df = [zeros(2*obj.numQ, 1), df];
            end
        end 
        function [f,df,r] = contactForce(obj,q, dq,u)
            %% CONTACTFORCE: Solves for the contact force at the given state
            %
            %   CONTACTFORCE solves for the contact force, given the state
            %   and the controls. Optionally, contactForce also returns the
            %   gradient of the force and the residual from the contact
            %   solver.
            %
            %   Syntax:
            %       [f, df, r] = contactForce(obj, q, dq, u);
            %       [f, df, r] = obj.contactForce(q, dq, u);
            %
            %   Arguments:
            %       OBJ: A DifferentiableContactDynamics model
            %       q:   Nx1 double, the configuration of the system
            %       dq:  Nx1 double, the configuration rate of the system
            %       u:   Mx1 double, the controls on the system
            %
            %   Return Values:
            %       f:  Kx1 double, the contact forces
            %       df: Kx(2N+M) double, the gradient of the contact force
            %           with respect to (q, dq, u)
            %       r:  scalar double, the residual from the contact solver
            
            % Get the parameters of the LCP problem
            [P, z, dP, dz, numF] = obj.getLCP(q, dq, u);
            % Solve the LCP
            [f,r] = obj.contactSolver.solve(P,z);
            % The gradient of the force
            if any(f(1:numF))
                df = obj.contactSolver.gradient(f, P, z, dP, dz);
                % Get only the normal and tangential components
                df = df(1:numF,:);
            else
                df = zeros(numF, 2*obj.numQ + obj.numU);
            end
            % Get the normal and tangential forces
            f = f(1:numF,:);
            % Convert impulse into force
            %f = f./obj.timestep;
            %df = df./obj.timestep;
        end

        function [P, z, dP, dz, numF] = getLCP(obj, q, dq, u)
            
            % Simulate forward one step
            qhat = q + dq * obj.timestep;
            % Get the system properties
            [M, C, B, dM, dC, dB]  = obj.manipulatorDynamics(qhat, dq);
            dM = reshape(dM', obj.numQ*[1,1,1]);
            dB = reshape(dB', [obj.numQ, obj.numU, obj.numQ]);
            % Invert the mass matrix, as we'll be using the inverse often
            R = chol(M);
            %iM = M\eye(obj.numQ);
            [Jn, Jt, dJn, dJt, alphas] = obj.contactJacobian(qhat);

            % Collect the contact Jacobian into one term:
            Jc = [Jn; Jt];
            dJc = cat(1,dJn, dJt);
            
            % Pre-initialize the arrays
            numT = size(Jt,1);
            numN = size(Jn,1);
            z = zeros(numT + 2*numN, 1);
            % Calculate the force effects, tau, and the no-contact velocity
            % vel:
            tau = B*u - C;
            vel = dq + obj.timestep * (R\(R'\tau));
           
            % The LCP offset vector
            z(1:numN) = Jn*vel + (Jn*q - alphas)/obj.timestep;
            z(numN+1:numN+numT) = Jt*vel;

            % Calculate the problem matrix 
            P = zeros(numT+2*numN, numT+2*numN);
            w = zeros(numN,numT);
            
            for n = 1:numN
                w(n,numT/numN*(n-1)+1:numT/numN*n) = 1;
            end
            Jr = Jc/R;            
            P(1:numN + numT, 1:numN + numT) = obj.timestep * (Jr * Jr');
            P(numN+1:numN+numT, numN+numT+1:end) = w';
            P(numN + numT+1:end,1:numN) = eye(numN) * obj.terrain.friction_coeff;
            P(numN+numT+1:end,numN+1:numN+numT) = -w;
            
            %% Gradient of the LCP Problem
            % Gradient of the problem matrix, dP
            % We'll also need the partial derivative of the inverse
            % mass matrix, so we'll calculate that here too.
            diM = zeros(obj.numQ*[1, 1, 1]);
            dP = zeros(numT+2*numN, numT+2*numN, 2*obj.numQ + obj.numU);
            for n = 1:obj.numQ
                diM(:,:,n) = -((R\(R'\dM(:,:,n)))/R)/R';
                dP(1:numN + numT, 1:numN + numT,n) = dJc(:,:,n) * (R\Jr') + Jc * diM(:,:,n) * Jc' + (Jr/R') * dJc(:,:,n)';
            end
            % Gradient of P wrt dq
            dP(:,:,obj.numQ+1:2*obj.numQ) = obj.timestep * dP(:,:,1:obj.numQ);
            dP = obj.timestep * dP;
            % Calculate the gradient of the offset vector, z:
            % First we do some multidimensional array multiplication:
            dBu = squeeze(sum(dB.*u', 2));            
            % Gradients of TAU wrt q, dq
            dtau_q = dBu - dC(:,1:obj.numQ);
            dtau_dq = -dC(:,obj.numQ+1:end) + obj.timestep*dtau_q;
            
            % Tensor Multiplications
            diM_tau = squeeze(sum(diM .* tau', 2));
            dJc_v = squeeze(sum(dJc .* vel', 2));           
            % Common terms to dz_q, dz_dq
            dz_common = dJc_v + obj.timestep * Jc * diM_tau;
            
            % Gradient wrt q, dq
            dz_q = dz_common + obj.timestep* (Jr/R') * dtau_q;
            dz_q(1:numN,:) = dz_q(1:numN,:) + Jn ./ obj.timestep;
            dz_dq = obj.timestep * dz_common + Jc * (eye(obj.numQ) + obj.timestep * (R\(R'\dtau_dq)));
            dz_u = obj.timestep * (Jr/R') * B;
            
            % Collect all the gradients in one
            dz = zeros(numT + 2*numN, 2*obj.numQ + obj.numU);
            dz(1:numT+numN, :) = [dz_q, dz_dq, dz_u];
            
            numF = numT + numN;
        end
        
        function [Jn, Jt, dJn, dJt, alphas] = contactJacobian(obj, q)
            
            
           % Get the Jacobian
           [J,dJ] = obj.jacobian(q);
            
           % Find the nearest point on the terrain 
           xA = obj.kinematics(q);
           [dim, nPoints] = size(xA);
           % Initialize
           Jn = zeros(nPoints,numel(q));
           dJn = zeros(nPoints, numel(q), numel(q));
           Jt = zeros(2*nPoints, numel(q));
           dJt = zeros(2*nPoints,numel(q),numel(q));
           phi = zeros(nPoints,1);
           for n = 1:nPoints
              [xB,dX] = obj.terrain.nearest(xA(:,n));
              [N,T,dN,dT] = obj.terrain.basis(xB);
              % Jacobian of the current point
              J_c = J((n-1)*dim+1:n*dim,:);
              dJ_c = dJ((n-1)*dim + 1 : n*dim, :, :);
              % Normal and tangential components
              Jn(n,:) = N'*J_c;
              Jt(2*n-1,:) = T'*J_c;
              Jt(2*n,:) = -T'*J_c;
              % Dervatives
              for k = 1:numel(q)
                  dJn(n,:,k) = (dN * dX * J_c(:,k))'*J_c + N'*dJ_c(:,:,k);
                  dJt(2*n-1,:,k) = (dT * dX * J_c(:,k))'*J_c + T'*dJ_c(:,:,k);
                  dJt(2*n,:,k) = -dJt(2*n-1,:,k);
              end
              % Calculate phi and alpha
              phi(n) = N'*(xA(:,n) - xB);
           end
           alphas = Jn * q - phi;
        end
                
        function [phi, Nw, Dw, xA, xB, iA, iB, mu, N, D, dN, dD] = contactConstraints(obj, q, ~,~) 
            %   Return Values
            %       phi: the signed distance between the manipulator and
            %       the ground
            %       Nw:  the contact normal expressed in world coordinates
            %       Dw: the friction basis expressed in world coordinates
            %       xA: the point on the manipulator nearest the terrain
            %       xB: the point on the terrain nearest the manipulator
            %       iA: the body index for the contact point xA (1)
            %       iB: the body index for the contact point xB (0)
            %       mu: the coefficient of friction
            %       N: the contact normal expressed in generalized
            %       coordinates
            %       D: the friction basis expressed in generalized
            %       coordinates
            %       dN: the derivative of N, dN/dq
            %       dD: the derivative of D, dD/dq
            
            % The body indices for the contactDrivenCart are fixed
            % quantities
            iA = 1; % Body A is the manipulator (the only body in the problem)
            iB = 0; % Body B is the terrain
                 
            % Get the jacobian
            [J, dJ] = obj.jacobian(q);
            
            % Number of contact points
            xA = obj.kinematics(q);
            [dim, nPoints] = size(xA);
            % Initialize loop outputs
            xB = zeros(size(xA));
            phi = zeros(nPoints,1);
            Nw = zeros(size(xA));
            Dw = cell(1);
            Dw{1} = zeros(size(xA));
            
            N = zeros(nPoints,numel(q));
            D = cell(2,1);
            dN = zeros(nPoints*numel(q), numel(q));
            dJN = zeros(nPoints, numel(q), numel(q));
            dJD = zeros(nPoints, numel(q), numel(q));
            dD = cell(2,1);
            dD{1} = zeros(nPoints*numel(q), numel(q));
            dD{2} = zeros(nPoints*numel(q), numel(q));

            for n = 1:nPoints
               % Get the nearest point on the terrain
               [xB(:,n), dXb] = obj.terrain.nearest(xA(:,n));
               % Terain basis vectors
               [Nw(:,n), Dw{1}(:,n), dNw, dTw] = obj.terrain.basis(xB(:,n));
               % Normal Distance
               phi(n) = Nw(:,n)'*(xA(:,n) - xB(:,n));
               % Jacobian of the current point
               J_c = J((n-1)*dim+1:n*dim,:);
               dJ_c = dJ((n-1)*dim + 1 : n*dim, :, :);
               % Normal and Tangent Vectors in Generalized Coordinates
               N(n,:) = Nw(:,n)'*J_c;
               D{1}(n,:) = Dw{1}(:,n)'*J_c;
               D{2}(n,:) = -D{1}(n,:);              
               % Derivatives of Normal and Tangent Vectors
               for k = 1:numel(q)
                  dJN(n,:,k) = (dNw * dXb * J_c(:,k))'*J_c + Nw(:,n)'*dJ_c(:,:,k); 
                  dJD(n,:,k) = (dTw * dXb * J_c(:,k))'*J_c + Dw{1}(:,n)'*dJ_c(:,:,k);
               end
            end
            % Reorganize the derivatives to match expected output
            for k = 1:numel(q)
               dN_ = dJN(:,:,k)';
               dN(:,k) = dN_(:);
               dT_ = dJD(:,:,k)';
               dD{1}(:,k) = dT_(:);
            end
            
            dD{2} = -dD{1};
            % Get friction
            mu = obj.terrain.friction_coeff;
            mu = mu * ones(nPoints,1);
%             % Friction is a property of the terrian
%             mu = obj.terrain.friction_coeff;
%             
%             % Get the nearest point from the terrain
%             xA = obj.kinematics(q);
%             xB = obj.terrain.nearest(xA);
%             
%             % Calculate the local coordinates of the terrain
%             [Nw, Tw] = obj.terrain.basis(xB);
%             % Expand Nw and Tw to select the appropriate contact point
%             Nw = mat2cell(Nw, size(Nw,1),ones(1,size(Nw,2)));
%             Tw = mat2cell(Tw, size(Tw,1), ones(1,size(Tw,2)));
%             Nw = blkdiag(Nw{:});
%             Tw = blkdiag(Tw{:});
%             Dw = {Tw};
%             % Calculate the signed distance function
%             phi = Nw' * (xA(:) - xB(:));
%             % Calculate N and D from the jacobian
%             [J, dJ] = obj.jacobian(q);
%             N = J' * Nw;
%             D = cell(2,1);
%             D{1} = J' * Tw;
%             D{2} = -D{1};
%             % Calculate dN and dD by contraction with dJacobian
%             dN = zeros(numel(N), numel(q));
%             dD = cell(2,1);
%             dD{1} = zeros(numel(D{1}),numel(q));
%             dD{2} = dD{1};
%             for n = 1:numel(q)
%                 tempN = dJ(:,:,n)'*Nw;
%                 dN(:,n) = tempN(:);
%                 tempD = dJ(:,:,n)'*Tw;
%                 dD{1}(:,n) = tempD(:);
%                 dD{2}(:,n) = -tempD(:);
%             end
%             % Format for output
%             N = N';
%             D{1} = D{1}';
%             D{2} = D{2}';
%             
            % Extend friction coefficient so there is 1 for every contact
%             mu = mu * ones(length(phi),1);
        end
        function obj = setupLCPCache(obj, t)
           % Set-up a cache for storing LCP results
           
           q = zeros(obj.numQ,1);
           [Jn,Jt] = obj.contactJacobian(q);
           numF = size(Jn,1) + size(Jt,1);
           
           f = zeros(numF, length(t));
           
           obj.lcpCache = SharedDataHandle(struct('time',t,'force',f));
           obj.cacheFlag = true;
        end
    end
    %% For drawing
    methods (Static)
        function [x, y] = drawLinkage(x0, y0, len, radius, phi)
            %% DRAWLINKAGE: Visualization method for generating drawings of linkages
            %
            %   drawLinkage can be used to draw 2D linkages in arbitrary
            %   configuruations. drawLinkage returns (x,y) coordinates for
            %   the boundary of a planar straight linkage with semicircular
            %   ends. 
            %
            %   Arguments
            %       x0: Scalar x coordinate for the horizontal origin of the linkage
            %       y0: Scalar y coordiante for the vertical origin of the linkage
            %       l:  Scalar length of the linkage
            %       r:  Scalar radius (half-width) of the linkage
            %       phi:    Orientation of the linkage with respect to the
            %       x-axis
            %
            %   Return Values:
            %       x: vector of x-coordinates for drawing the linkage
            %       y: vector of y-coordinates for drawing the linkage
            %
            %   Note: The length of the returned linkage is increased by 2r
            %   due to the circular endcaps
            %
            %   Using the output of drawLinkage, plot(x,y) should create an
            %   image of the linkage.
            %% Draw a standard linkage
            th = pi*(0:0.01:1);
            x = [0, radius*cos(th + pi/2), 0, len, radius*cos(th+ 3*pi/2)+len, len, 0];
            y = [radius, radius*sin(th+pi/2), -radius, -radius, radius*sin(th+3*pi/2), radius, radius];
            
            %% Transform the standard linkage into the new linkage
            % Create the shifting, scaling, and rotation transforms
            Shift = eye(3);
            Shift(1:2,3) = [x0; y0];
            Rot = eye(3);
            Rot(1:2,1:2) = [cos(phi), -sin(phi);
                sin(phi), cos(phi)];
            % Combine the points into one array
            P0 = [x; y; ones(1,length(x))];
            % Transform
            P = Shift * Rot * P0;
            
            x = P(1,:);
            y = P(2,:);
        end
    end
end

