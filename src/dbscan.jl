# if channelresult already has abovethreshold set, it'll use that instead of recalculating.

function dbscan!(channels::Vector{ChannelResult}, epsilon, minpoints, uselocalradius_threshold, localradius)
    for c ∈ channels
        if uselocalradius_threshold && isnothing(c.pointdata.abovethreshold)
            allcoordinates = reduce(hcat, c.coordinates for c ∈ channels)
            allneighbortree = BallTree(allcoordinates)
            nneighbors = inrangecount(allneighbortree, c.coordinates, localradius, true)
            equivalentradii = equivalentradius.(nneighbors, ntotal, roiarea)
            c.pointdata.abovethreshold = equivalentradii .> localradius # maybe can replace with simple number threshold though, if don't need to compare across channels
        end
        coordinates = uselocalradius_threshold ? c.coordinates[:, c.pointdata.abovethreshold] : c.coordinates
        clusters = Clustering.dbscan(coordinates, epsilon, min_cluster_size = minpoints)
        c.clusterdata = DataFrame(:cluster => clusters, :size => [cluster.size for cluster ∈ clusters])
        c.nclusters = length(clusters)
        c.roiclusterdensity = c.nclusters / c.roiarea
        c.meanclustersize = mean(c.clusterdata.size)
        c.fraction_clustered = (c.nlocalizations - sum(c.clusterdata.size)) / c.nlocalizations
    end
end