---
layout: page
title: About Me
permalink: /about/
---
<div class="row">
    <div class="col-lg-offset-0">
        <div class="panel panel-default">
            <div class="panel-body">
                <div class="row">
                    <div class="col-lg-12">
                        <div class="row">
                            <div class="col-sm-offset-3 col-sm-6 col-md-offset-3 col-md-6 col-lg-offset-3 col-lg-6">
                                <img class="img-responsive"
                                     src="{{site.data.personal.gravatar}}">
                            </div>
                        </div>
                    </div>
                </div>

                <div class="row">
                    <div class="col-lg-12">
                        <div class="row">
                            <div class="centered-text col-sm-offset-3 col-sm-6 col-md-offset-3 col-md-6 col-lg-offset-3 col-lg-6">

                                <div itemscope itemtype="http://schema.org/Person" >
                                    <h2> <span itemprop="name">{{site.data.personal.name}}</span></h2>
                                    <p itemprop="jobTitle">{{site.data.personal.position}}</p>
                                    <p><span itemprop="affiliation">{{site.data.personal.company}}</span></p>
                                    <p>
                                    <i class="fa fa-map-marker"></i> <span itemprop="addressRegion">{{site.data.personal.location}}</span>
                                    </p>
                                    <p itemprop="email"> <i class="fa fa-envelope">&nbsp;</i> <a href="mailto:{{site.data.personal.email}}">{{site.data.personal.email}}</a> </p>
                                    <p itemprop="book"> <i class="fa fa-book">&nbsp;</i>{{site.data.personal.book}}</p>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

